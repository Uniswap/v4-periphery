// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {IMorpho, MarketParams, Id} from "morpho-blue/interfaces/IMorpho.sol";
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

import {IWETH9} from "../../src/interfaces/external/IWETH9.sol";
import {MarginRouter} from "../../src/MarginRouter.sol";
import {IMarginRouter} from "../../src/interfaces/IMarginRouter.sol";
import {MarginAccount} from "../../src/MarginAccount.sol";
import {MorphoLendingAdapter} from "../../src/MorphoLendingAdapter.sol";
import {IV4Router} from "../../src/interfaces/IV4Router.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {MarginActions} from "../../src/libraries/MarginActions.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";
import {Market} from "../../src/types/Market.sol";
import {Ltv, toLtv} from "../../src/types/Ltv.sol";
import {Plan, Planner} from "../shared/Planner.sol";

/// @notice Fork tests for the generalized `execute` entrypoint against live Morpho Blue. Proves the
///         arbitrary-plan path composes with the real lending leg exactly as the curated entry
///         points do (open parity), supports repay-from-wallet via real Permit2, and can pay equity
///         in a token other than the collateral by converting it through a local v4 pool in the same
///         atomic plan (the WBTC-funded WETH/USDC long from the design discussion).
contract MarginRouterExecuteForkTest is Test {
    using MarketParamsLib for MarketParams;
    using Planner for Plan;

    IMorpho internal constant MORPHO = IMorpho(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599; // 8 decimals
    address internal constant ORACLE = 0xdC6fd5831277c693b1054e19E94047cB37c77615;
    address internal constant IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint256 internal constant LLTV = 0.86e18;
    uint256 internal constant FORK_BLOCK = 25_319_047;

    int24 internal constant MIN_TICK = -887_220;
    int24 internal constant MAX_TICK = 887_220;
    uint24 internal constant POOL_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;

    // local WBTC/WETH pool price: 1 WBTC ≈ 15 WETH. Arbitrary but realistic; only needs to let the
    // dealt WBTC equity convert into enough WETH for the open. token0 = WBTC (0x22 < 0xC0 = WETH).
    uint256 internal constant WETH_PER_WBTC = 15;

    PoolManager internal manager;
    PoolModifyLiquidityTest internal lpRouter;
    MorphoLendingAdapter internal adapter;
    MarginRouter internal router;

    MarketParams internal marketParams;
    Market internal market;
    PoolKey internal poolKey; // USDC/WETH (the leverage pool)
    PoolKey internal wbtcKey; // WBTC/WETH (the equity-conversion pool)

    receive() external payable {}

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        vm.skip(bytes(rpc).length == 0);
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, FORK_BLOCK);

        marketParams = MarketParams({loanToken: USDC, collateralToken: WETH, oracle: ORACLE, irm: IRM, lltv: LLTV});
        market = Market({collateral: Currency.wrap(WETH), debt: Currency.wrap(USDC)});

        assertEq(MORPHO.idToMarketParams(marketParams.id()).collateralToken, WETH, "market collateral");
        assertGt(PERMIT2.code.length, 0, "permit2 deployed");

        manager = new PoolManager(address(this));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        _initAndSeedUsdcWethPool();
        _initAndSeedWbtcWethPool();

        adapter = new MorphoLendingAdapter(MORPHO, address(this));
        adapter.setMarket(marketParams);

        address impl = address(new MarginAccount());
        router = new MarginRouter(
            IPoolManager(address(manager)), IAllowanceTransfer(PERMIT2), IWETH9(WETH), impl, address(this)
        );
        router.setAdapterAllowed(adapter, true);

        // extra lender-side USDC so several borrows are comfortably funded
        _seedMorphoLiquidity(5_000_000e6);
    }

    /// @notice An execute-built open reaches the same live-market state as the curated increase, run
    ///         from an identical fork snapshot so the swap prices match.
    function test_fork_execute_openMatchesCurated() public {
        _approvePermit2Equity(WETH, 1 ether);
        address account = router.accountOf(address(this), 0);

        uint256 snap = vm.snapshotState();

        router.increasePosition(
            IMarginRouter.IncreaseParams({
                adapter: adapter,
                market: market,
                poolKey: poolKey,
                equity: 1 ether,
                collateralToBuy: 1 ether,
                maxDebtIn: 10_000e6,
                minHopPriceX36: 0,
                maxLtvAfter: Ltv.wrap(0),
                subId: 0,
                deadline: block.timestamp + 1 hours
            })
        );
        (uint256 curatedColl, uint256 curatedDebt) = adapter.positionOf(account, market);

        vm.revertToState(snap);

        // execute-built open with identical inputs: pull equity via Permit2 into the account, buy
        // 1 WETH exact-out, take, supply, borrow the USDC owed, settle
        bool zeroForOne = market.toSwapParams(market.debt, 0, 0, poolKey).zeroForOne;
        Plan memory plan = Planner.init();
        plan = plan.add(MarginActions.SET_ACCOUNT, abi.encode(uint256(0)));
        plan = plan.add(MarginActions.PULL_TO_ACCOUNT, abi.encode(market.collateral, uint256(1 ether), true));
        plan = plan.add(
            Actions.SWAP_EXACT_OUT_SINGLE,
            abi.encode(
                IV4Router.ExactOutputSingleParams({
                    poolKey: poolKey,
                    zeroForOne: zeroForOne,
                    amountOut: 1 ether,
                    amountInMaximum: 10_000e6,
                    minHopPriceX36: 0,
                    hookData: ""
                })
            )
        );
        plan = plan.add(MarginActions.ASSERT_FILL, abi.encode(market.collateral, uint256(1 ether)));
        plan = plan.add(Actions.TAKE, abi.encode(market.collateral, account, ActionConstants.OPEN_DELTA));
        plan =
            plan.add(MarginActions.ACCOUNT_SUPPLY_COLLATERAL, abi.encode(adapter, market, ActionConstants.OPEN_DELTA));
        plan = plan.add(
            MarginActions.ACCOUNT_BORROW, abi.encode(adapter, market, ActionConstants.OPEN_DELTA, address(router))
        );
        plan = plan.add(Actions.SETTLE, abi.encode(market.debt, ActionConstants.OPEN_DELTA, false));
        router.execute(plan.encode(), block.timestamp + 1 hours);

        (uint256 execColl, uint256 execDebt) = adapter.positionOf(account, market);
        assertApproxEqAbs(execColl, curatedColl, 1, "collateral parity vs curated");
        assertApproxEqAbs(execDebt, curatedDebt, 2, "debt parity vs curated");
        _assertNoDust(account);
    }

    /// @notice Repay a live-Morpho position entirely from the caller's wallet via Permit2, selling no
    ///         collateral: PULL the USDC in, repay all by shares. Collateral is untouched.
    function test_fork_execute_repayFromWallet() public {
        address account = _openViaCurated(1 ether, 1 ether);
        (uint256 collBefore, uint256 debtOwed) = adapter.positionOf(account, market);
        assertGt(debtOwed, 0, "position has debt");

        // fund exactly the current debt (no warp between the read and the call, so no accrual) and
        // approve Permit2; repay-all-by-shares consumes it
        deal(USDC, address(this), debtOwed);
        _approvePermit2Equity(USDC, uint160(debtOwed));

        Plan memory plan = Planner.init();
        plan = plan.add(MarginActions.SET_ACCOUNT, abi.encode(uint256(0)));
        plan = plan.add(MarginActions.PULL_TO_ACCOUNT, abi.encode(market.debt, debtOwed, true));
        plan = plan.add(MarginActions.ACCOUNT_REPAY, abi.encode(adapter, market, type(uint256).max));
        router.execute(plan.encode(), block.timestamp + 1 hours);

        (uint256 collAfter, uint256 debtAfter) = adapter.positionOf(account, market);
        assertEq(debtAfter, 0, "debt fully repaid from wallet");
        assertApproxEqAbs(collAfter, collBefore, 1, "collateral untouched");
    }

    /// @notice Pay equity in WBTC for a WETH/USDC long: convert WBTC->WETH through the local pool,
    ///         then open the leveraged position, all in one atomic plan. The WBTC-funded long from
    ///         the design discussion, proving the routing surface composes with the lending leg.
    function test_fork_execute_wbtcEquityLong() public {
        uint256 equityWbtc = 0.1e8; // 0.1 WBTC ≈ 1.5 WETH at the seeded price
        uint128 buy = 1 ether; // leverage: buy 1 WETH with borrowed USDC
        address account = router.accountOf(address(this), 0);

        deal(WBTC, address(this), equityWbtc);
        _approvePermit2Equity(WBTC, uint160(equityWbtc));

        bool wbtcZeroForOne = wbtcKey.currency0 == Currency.wrap(WBTC); // selling WBTC
        bool debtZeroForOne = market.toSwapParams(market.debt, 0, 0, poolKey).zeroForOne;

        Plan memory plan = Planner.init();
        plan = plan.add(MarginActions.SET_ACCOUNT, abi.encode(uint256(0)));
        // equity conversion: sell all WBTC for WETH (exact-in)
        plan = plan.add(
            Actions.SWAP_EXACT_IN_SINGLE,
            abi.encode(
                IV4Router.ExactInputSingleParams({
                    poolKey: wbtcKey,
                    zeroForOne: wbtcZeroForOne,
                    amountIn: uint128(equityWbtc),
                    amountOutMinimum: 0,
                    minHopPriceX36: 0,
                    hookData: ""
                })
            )
        );
        // leverage: buy `buy` WETH selling borrowed USDC (exact-out)
        plan = plan.add(
            Actions.SWAP_EXACT_OUT_SINGLE,
            abi.encode(
                IV4Router.ExactOutputSingleParams({
                    poolKey: poolKey,
                    zeroForOne: debtZeroForOne,
                    amountOut: buy,
                    amountInMaximum: 10_000e6,
                    minHopPriceX36: 0,
                    hookData: ""
                })
            )
        );
        // take the combined WETH credit (converted equity + bought) to the account and supply it
        plan = plan.add(Actions.TAKE, abi.encode(market.collateral, account, ActionConstants.OPEN_DELTA));
        plan =
            plan.add(MarginActions.ACCOUNT_SUPPLY_COLLATERAL, abi.encode(adapter, market, ActionConstants.OPEN_DELTA));
        // borrow the USDC owed for the leverage swap, settle both swap inputs
        plan = plan.add(
            MarginActions.ACCOUNT_BORROW, abi.encode(adapter, market, ActionConstants.OPEN_DELTA, address(router))
        );
        plan = plan.add(Actions.SETTLE, abi.encode(market.debt, ActionConstants.OPEN_DELTA, false)); // USDC from router
        plan = plan.add(Actions.SETTLE, abi.encode(Currency.wrap(WBTC), ActionConstants.OPEN_DELTA, true)); // WBTC from caller
        router.execute(plan.encode(), block.timestamp + 1 hours);

        (uint256 coll, uint256 debt) = adapter.positionOf(account, market);
        // collateral = converted equity (~1.5 WETH) + bought (1 WETH), minus swap fees/slippage
        assertGt(coll, 2.3 ether, "collateral = converted WBTC equity + leverage");
        assertLt(coll, 2.6 ether, "collateral within expected band");
        assertGt(debt, 0, "USDC debt drawn");
        assertLt(Ltv.unwrap(adapter.currentLtvWad(account, market)), LLTV, "healthy");
        _assertNoDust(account);
        assertEq(IERC20(WBTC).balanceOf(address(router)), 0, "router holds no WBTC");
        console2.log("WBTC-funded long collateral (WETH wei):", coll);
    }

    // ───────────────────────────────────────── Helpers ──────────────────────────────────────────

    function _openViaCurated(uint256 equity, uint128 buy) internal returns (address account) {
        account = router.accountOf(address(this), 0);
        _approvePermit2Equity(WETH, uint160(equity));
        router.increasePosition(
            IMarginRouter.IncreaseParams({
                adapter: adapter,
                market: market,
                poolKey: poolKey,
                equity: equity,
                collateralToBuy: buy,
                maxDebtIn: 10_000e6,
                minHopPriceX36: 0,
                maxLtvAfter: Ltv.wrap(0),
                subId: 0,
                deadline: block.timestamp + 1 hours
            })
        );
    }

    function _initAndSeedUsdcWethPool() internal {
        require(USDC < WETH, "usdc/weth ordering");
        poolKey = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(WETH),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        uint256 oraclePrice = IOracle(ORACLE).price();
        uint256 priceX192 = FullMath.mulDiv(1e36, uint256(1) << 192, oraclePrice);
        uint160 sqrtPriceX96 = uint160(FixedPointMathLib.sqrt(priceX192));
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

    function _initAndSeedWbtcWethPool() internal {
        require(WBTC < WETH, "wbtc/weth ordering");
        wbtcKey = PoolKey({
            currency0: Currency.wrap(WBTC),
            currency1: Currency.wrap(WETH),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        // v4 price = token1/token0 = WETH_raw per WBTC_raw = WETH_PER_WBTC * 1e18 / 1e8 = 15 * 1e10
        uint256 price = WETH_PER_WBTC * 1e10;
        uint160 sqrtPriceX96 = uint160(FixedPointMathLib.sqrt(price << 192));
        require(sqrtPriceX96 > TickMath.MIN_SQRT_PRICE && sqrtPriceX96 < TickMath.MAX_SQRT_PRICE, "wbtc price bounds");
        manager.initialize(wbtcKey, sqrtPriceX96);

        deal(WBTC, address(this), 10_000e8);
        // WETH already dealt in the USDC/WETH seed; top up to be safe
        deal(WETH, address(this), IERC20(WETH).balanceOf(address(this)) + 1_000_000 ether);
        IERC20(WBTC).approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            wbtcKey,
            ModifyLiquidityParams({tickLower: MIN_TICK, tickUpper: MAX_TICK, liquidityDelta: 1e15, salt: 0}),
            ""
        );
    }

    function _seedMorphoLiquidity(uint256 assets) internal {
        address lender = makeAddr("lender");
        deal(USDC, lender, assets);
        vm.startPrank(lender);
        IERC20(USDC).approve(address(MORPHO), assets);
        MORPHO.supply(marketParams, assets, 0, lender, "");
        vm.stopPrank();
    }

    function _approvePermit2Equity(address token, uint160 amount) internal {
        IERC20(token).approve(PERMIT2, type(uint256).max);
        IAllowanceTransfer(PERMIT2).approve(token, address(router), amount, uint48(block.timestamp + 1 hours));
    }

    function _assertNoDust(address account) internal view {
        assertEq(IERC20(WETH).balanceOf(account), 0, "account holds no loose WETH");
        assertEq(IERC20(USDC).balanceOf(account), 0, "account holds no loose USDC");
        assertEq(IERC20(WETH).balanceOf(address(router)), 0, "router holds no loose WETH");
        assertEq(IERC20(USDC).balanceOf(address(router)), 0, "router holds no loose USDC");
    }
}
