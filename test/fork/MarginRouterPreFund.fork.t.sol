// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MarginRouteHelpers} from "../shared/MarginRouteHelpers.sol";

import {IMorpho, MarketParams} from "morpho-blue/interfaces/IMorpho.sol";
import {IOracle} from "morpho-blue/interfaces/IOracle.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Commands} from "universal-router/contracts/libraries/Commands.sol";

import {IWETH9} from "../../src/interfaces/external/IWETH9.sol";
import {IMarginRouter} from "../../src/interfaces/IMarginRouter.sol";
import {MarginAccount} from "../../src/MarginAccount.sol";
import {MorphoLendingAdapter} from "../../src/MorphoLendingAdapter.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";
import {Market} from "../../src/types/Market.sol";
import {Ltv} from "../../src/types/Ltv.sol";

/// @notice Sherlock #1 against the live venue. A Universal Router pre-funded with at least what a
///         route costs, swept back to the margin router with the change (the guide's postcondition
///         for a route that custodies input in the Universal Router), nets the route's spend to
///         zero. The curated increase then asks Morpho to borrow zero and the partial decrease asks
///         it to withdraw zero, and Morpho rejects both. The documented `V4_SWAP` route, paid
///         straight from the router through Permit2, never touches the Universal Router's balance
///         and is unaffected.
contract MarginRouterPreFundForkTest is Test, MarginRouteHelpers {
    using MarketParamsLib for MarketParams;

    // verified on mainnet (see setUp assertions / canonical registries)
    IMorpho internal constant MORPHO = IMorpho(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant ORACLE = 0xdC6fd5831277c693b1054e19E94047cB37c77615;
    address internal constant IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint256 internal constant LLTV = 0.86e18;
    uint256 internal constant FORK_BLOCK = 25_319_047;

    // full range for tickSpacing 60 (matches the shared routing helpers)
    int24 internal constant MIN_TICK = -887_220;
    int24 internal constant MAX_TICK = 887_220;
    uint24 internal constant POOL_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;

    uint256 internal constant EQUITY = 1 ether;
    uint128 internal constant BUY = 1 ether;
    uint128 internal constant MAX_DEBT_IN = 20_000e6;
    uint128 internal constant REPAY = 500e6;
    uint128 internal constant MAX_COLLATERAL_IN = 1 ether;

    PoolManager internal manager;
    PoolModifyLiquidityTest internal lpRouter;
    MorphoLendingAdapter internal adapter;
    IMarginRouter internal router;
    address internal ur;

    MarketParams internal marketParams;
    Market internal market;
    PoolKey internal poolKey;

    /// @dev PoolModifyLiquidityTest refunds leftover native dust to the caller.
    receive() external payable {}

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        vm.skip(bytes(rpc).length == 0);
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, FORK_BLOCK);

        marketParams = MarketParams({loanToken: USDC, collateralToken: WETH, oracle: ORACLE, irm: IRM, lltv: LLTV});
        market =
            Market({collateral: Currency.wrap(WETH), debt: Currency.wrap(USDC), data: abi.encode(ORACLE, IRM, LLTV)});
        assertEq(MORPHO.idToMarketParams(marketParams.id()).collateralToken, WETH, "market collateral");
        assertEq(MORPHO.idToMarketParams(marketParams.id()).loanToken, USDC, "market loan token");

        manager = new PoolManager(address(this));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        _initAndSeedPool();

        adapter = new MorphoLendingAdapter(MORPHO);
        address impl = address(new MarginAccount());
        ur = deployUniversalRouter(address(manager), PERMIT2, WETH);
        router = IMarginRouter(
            deployMarginRouter(IPoolManager(address(manager)), IAllowanceTransfer(PERMIT2), IWETH9(WETH), impl)
        );
    }

    /// @notice The documented route is immune: the pre-fund is never part of the route's balance, so
    ///         the position borrows the real cost and the pre-fund stays on the Universal Router.
    function test_fork_increase_documentedRoute_ignoresPreFund() public {
        address account = _fundAccount(0);
        deal(USDC, ur, MAX_DEBT_IN);
        (bytes memory cmds, bytes[] memory ins) =
            buildV4ExactOutRoute(poolKey, market.debt, market.collateral, BUY, MAX_DEBT_IN, account);

        router.increasePosition(_increaseParams(0, cmds, ins));

        (uint256 coll, uint256 debt) = adapter.positionOf(account, market);
        assertEq(coll, EQUITY + BUY, "collateral supplied");
        assertGt(debt, 0, "the position borrowed the swap's cost");
        assertEq(IERC20(USDC).balanceOf(ur), MAX_DEBT_IN, "the pre-fund was never touched");
    }

    /// @notice A pre-fund of at least the cost, swept back with the change, zeroes the borrow and
    ///         Morpho rejects it: `borrow(0 assets, 0 shares)` is `inconsistent input`.
    function test_fork_increase_preFundAtLeastCost_revertsOnMorpho() public {
        address account = _fundAccount(0);
        deal(USDC, ur, MAX_DEBT_IN);
        (bytes memory cmds, bytes[] memory ins) =
            _sweepSuffixedRoute(market.debt, market.collateral, BUY, MAX_DEBT_IN, account);

        vm.expectRevert(bytes("inconsistent input"));
        router.increasePosition(_increaseParams(0, cmds, ins));

        assertEq(IERC20(USDC).balanceOf(ur), MAX_DEBT_IN, "the pre-fund is still on the Universal Router");
    }

    /// @notice Same on the partial decrease: the collateral withdrawal resolves to zero and Morpho
    ///         rejects it with `zero assets`.
    function test_fork_decrease_preFundAtLeastCost_revertsOnMorpho() public {
        address account = _fundAccount(0);
        (bytes memory openCmds, bytes[] memory openIns) =
            buildV4ExactOutRoute(poolKey, market.debt, market.collateral, BUY, MAX_DEBT_IN, account);
        router.increasePosition(_increaseParams(0, openCmds, openIns));

        deal(WETH, ur, MAX_COLLATERAL_IN);
        (bytes memory cmds, bytes[] memory ins) =
            _sweepSuffixedRoute(market.collateral, market.debt, REPAY, MAX_COLLATERAL_IN, account);

        vm.expectRevert(bytes("zero assets"));
        router.decreasePosition(_decreaseParams(0, cmds, ins));

        assertEq(IERC20(WETH).balanceOf(ur), MAX_COLLATERAL_IN, "the pre-fund is still on the Universal Router");
    }

    // -------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------

    /// @dev The account for `subId`, holding `EQUITY` WETH as its equity (no Permit2 pull needed).
    function _fundAccount(uint256 subId) internal returns (address account) {
        account = router.accountOf(address(this), subId);
        deal(WETH, account, EQUITY);
    }

    function _increaseParams(uint256 subId, bytes memory commands, bytes[] memory inputs)
        internal
        view
        returns (IMarginRouter.IncreaseParams memory)
    {
        return IMarginRouter.IncreaseParams({
            adapter: adapter,
            market: market,
            equity: 0,
            collateralToBuy: BUY,
            maxDebtIn: MAX_DEBT_IN,
            universalRouter: ur,
            routeCommands: commands,
            routeInputs: inputs,
            maxLtvAfter: Ltv.wrap(0),
            subId: subId,
            deadline: block.timestamp + 1 hours
        });
    }

    function _decreaseParams(uint256 subId, bytes memory commands, bytes[] memory inputs)
        internal
        view
        returns (IMarginRouter.DecreaseParams memory)
    {
        return IMarginRouter.DecreaseParams({
            adapter: adapter,
            market: market,
            debtToRepay: REPAY,
            maxCollateralIn: MAX_COLLATERAL_IN,
            universalRouter: ur,
            routeCommands: commands,
            routeInputs: inputs,
            maxLtvAfter: Ltv.wrap(LLTV), // a partial decrease must carry a bound
            subId: subId,
            deadline: block.timestamp + 1 hours
        });
    }

    /// @dev The documented route with a whole-balance sweep of the input back to the router appended:
    ///      the guide's postcondition for a route that custodies input in the Universal Router, and
    ///      the shape that carries a pre-fund back.
    function _sweepSuffixedRoute(Currency input, Currency output, uint128 amountOut, uint128 maxIn, address recipient)
        internal
        view
        returns (bytes memory commands, bytes[] memory inputs)
    {
        (bytes memory baseCommands, bytes[] memory baseInputs) =
            buildV4ExactOutRoute(poolKey, input, output, amountOut, maxIn, recipient);
        commands = abi.encodePacked(baseCommands, uint8(Commands.SWEEP));
        inputs = new bytes[](2);
        inputs[0] = baseInputs[0];
        inputs[1] = abi.encode(Currency.unwrap(input), ActionConstants.MSG_SENDER, uint256(0));
    }

    /// @notice Initializes the USDC/WETH pool at the live oracle price and seeds deep full-range
    ///         liquidity, so the swap leg values WETH the same way Morpho does.
    function _initAndSeedPool() internal {
        require(USDC < WETH, "currency ordering");
        poolKey = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(WETH),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        // Morpho oracle: USDC_raw = WETH_raw * price / 1e36. The v4 price is token1/token0 =
        // WETH_raw/USDC_raw = 1e36 / price. sqrtPriceX96 = sqrt(v4price * 2^192).
        uint256 oraclePrice = IOracle(ORACLE).price();
        uint256 priceX192 = FullMath.mulDiv(1e36, uint256(1) << 192, oraclePrice);
        uint160 sqrtPriceX96 = uint160(FixedPointMathLib.sqrt(priceX192));
        require(sqrtPriceX96 > TickMath.MIN_SQRT_PRICE && sqrtPriceX96 < TickMath.MAX_SQRT_PRICE, "price bounds");

        manager.initialize(poolKey, sqrtPriceX96);

        deal(WETH, address(this), 1_000_000 ether);
        deal(USDC, address(this), 100_000_000_000e6);
        IERC20(WETH).approve(address(lpRouter), type(uint256).max);
        IERC20(USDC).approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: MIN_TICK, tickUpper: MAX_TICK, liquidityDelta: 1e18, salt: 0}),
            ""
        );
    }
}
