// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {MarginRouteHelpers} from "../shared/MarginRouteHelpers.sol";
import {Commands} from "universal-router/contracts/libraries/Commands.sol";

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
import {IMarginRouter} from "../../src/interfaces/IMarginRouter.sol";
import {IV4Router} from "../../src/interfaces/IV4Router.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";
import {MarginAccount} from "../../src/MarginAccount.sol";
import {AaveV4LendingAdapter} from "../../src/AaveV4LendingAdapter.sol";
import {ISpoke} from "../../src/interfaces/external/aave-v4/ISpoke.sol";
import {IAaveOracle} from "../../src/interfaces/external/aave-v4/IAaveOracle.sol";
import {Market} from "../../src/types/Market.sol";
import {Ltv, toLtv} from "../../src/types/Ltv.sol";
import {PositionData} from "../../src/types/PositionData.sol";

/// @notice Full-stack mainnet-fork test of a real ETH SHORT against the live Aave v4 deployment. The
///         position supplies USDC as collateral and borrows real WETH on the Aave v4 Main Spoke,
///         routed through the entire margin stack at once:
///
///         MarginRouter (unlock + flash accounting + delta resolution)
///           -> V4Router swap through a real PoolManager
///           -> AaveV4LendingAdapter encodes real Aave v4 Spoke calls
///           -> MarginAccount executes them as itself, supplying + enabling collateral via the Spoke
///              multicall, borrowing WETH and forwarding it to the router
///           -> real Aave v4 variable-rate + premium accrual
///
///         The market pairs USDC (6 decimals, reserveId 7) as collateral and WETH (18 decimals,
///         reserveId 0) as debt, so the caller is long USDC and short WETH. Unlike Aave v3, the v4
///         oracle is reserveId-keyed and supply does not auto-enable collateral; both are exercised
///         here. The Spoke, Hub, oracle, reserve underlyings, and collateral factor are all verified
///         on-chain in setUp. The only locally-deployed venue is the v4 pool, seeded with deep
///         full-range liquidity at the live Aave oracle price so the swap and lending legs agree.
contract AaveV4LendingAdapterForkTest is Test, MarginRouteHelpers {
    // canonical Aave v4 mainnet addresses (bgd-labs/aave-address-book), verified on-chain in setUp
    address internal constant MAIN_SPOKE = 0x94e7A5dCbE816e498b89aB752661904E2F56c485;
    address internal constant CORE_HUB = 0xCca852Bc40e560adC3b1Cc58CA5b55638ce826c9;
    address internal constant EXPECTED_ORACLE = 0x99B2B6CEa9C3D2fd8F4d90f86741C44B212a6127;

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // reserve ids on the Main Spoke
    uint256 internal constant WETH_RESERVE_ID = 0;
    uint256 internal constant USDC_RESERVE_ID = 7;
    // USDC collateral factor on the live reserve, in basis points (78%).
    uint256 internal constant USDC_CF_BPS = 7800;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 1e4;

    // canonical Permit2, identical address on every chain (unused here; pre-fund equity path is taken)
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint256 internal constant FORK_BLOCK = 25_330_047;

    // full range for tickSpacing 60 (matches the shared routing helpers)
    int24 internal constant MIN_TICK = -887_220;
    int24 internal constant MAX_TICK = 887_220;
    uint24 internal constant POOL_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;

    PoolManager internal manager;
    PoolModifyLiquidityTest internal lpRouter;
    AaveV4LendingAdapter internal adapter;
    IMarginRouter internal router;
    address internal ur;

    Market internal market;
    PoolKey internal poolKey;
    PoolKey internal nativePoolKey;

    // live Aave v4 oracle prices (USD base, 8 decimals), read in setUp.
    uint256 internal usdcPriceBase;
    uint256 internal wethPriceBase;

    /// @dev Receives the native refund `PoolModifyLiquidityTest` returns after seeding a native pool.
    receive() external payable {}

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        vm.skip(bytes(rpc).length == 0);
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, FORK_BLOCK);

        // the short market: USDC collateral, WETH debt (long USDC, short WETH)
        // Aave v4 keys a market by per-Spoke reserve ids, carried in the key data
        market = Market({
            collateral: Currency.wrap(USDC),
            debt: Currency.wrap(WETH),
            data: abi.encode(USDC_RESERVE_ID, WETH_RESERVE_ID)
        });

        _deployAndVerifyAdapter();
        _readOraclePrices();

        // a real, freshly-deployed v4 PoolManager and a USDC/WETH pool priced at the Aave oracle
        manager = new PoolManager(address(this));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        _initAndSeedPool();

        // the full margin stack, wired to the live Aave v4 Spoke, canonical Permit2, and WETH9
        address impl = address(new MarginAccount());
        // route position swaps through a Universal Router bound to the local flash-take PoolManager
        ur = deployUniversalRouter(address(manager), PERMIT2, WETH);
        router = IMarginRouter(
            deployMarginRouter(IPoolManager(address(manager)), IAllowanceTransfer(PERMIT2), IWETH9(WETH), impl)
        );
    }

    /// @notice Proves a real ETH short composes across a full lifecycle against live Aave v4: open a
    ///         USDC-collateralized WETH borrow, accrue interest, partially delever, then fully unwind.
    ///         Each stage reads the real position state through the adapter and the live Spoke, so the
    ///         assertions exercise the read path on the live protocol.
    function test_fork_shortEth_fullLifecycle() public {
        address account = router.accountOf(address(this), 0);

        _stageOpen(account);
        _stageAccrueInterest(account);
        _stageDecrease(account);
        _stageClose(account);
    }

    /// @notice A WETH-denominated increase whose v4 pool is native: the route pulls the whole cap as
    ///         WETH, unwraps it, settles the native swap from the Universal Router's balance, and wraps
    ///         the unspent change back to WETH for the account (the universal-router-sdk's default
    ///         recipient). The router sweeps that change back and settles it, so the short borrows the
    ///         real WETH cost of the swap rather than the whole cap, and no WETH stays idle in the
    ///         account.
    function test_fork_shortEth_nativeWethRoute_changeToAccount_borrowsOnlyActualCost() public {
        _initAndSeedNativePool();
        address account = router.accountOf(address(this), 0);
        uint128 maxDebtIn = _maxDebtForUsdc(2000e6);

        _openViaNativeRoute(0, account, account);

        _assertBorrowedActualCost(account, maxDebtIn);
    }

    /// @notice The documented shape, wrapping the change to `MSG_SENDER` so it returns to the margin
    ///         router, accounts for the same actual cost.
    function test_fork_shortEth_nativeWethRoute_changeToRouter_borrowsOnlyActualCost() public {
        _initAndSeedNativePool();
        address account = router.accountOf(address(this), 0);
        uint128 maxDebtIn = _maxDebtForUsdc(2000e6);

        _openViaNativeRoute(0, account, ActionConstants.MSG_SENDER);

        _assertBorrowedActualCost(account, maxDebtIn);
    }

    /// @notice A full close does not depend on the Spoke's oracle. The Spoke's `withdraw` prices every
    ///         reserve still flagged as collateral, so with the oracle reverting the close only
    ///         succeeds because the adapter clears the collateral flag, after the close's repay has
    ///         cleared the borrow, before it withdraws.
    function test_fork_shortEth_fullClose_succeedsDuringOracleOutage() public {
        address account = router.accountOf(address(this), 0);
        _stageOpen(account);

        // the oracle now reverts for every call
        vm.etch(EXPECTED_ORACLE, hex"60006000fd");
        vm.expectRevert();
        ISpoke(MAIN_SPOKE).getUserAccountData(account);

        _stageClose(account);
    }

    /// @notice With no debt in the market the adapter reports a zero LTV without calling the Spoke's
    ///         account-level read, so the mandatory health assertion of a debt-clearing partial
    ///         decrease does not consult the oracle. Checked on the live Spoke with the oracle
    ///         reverting. A partial decrease as a whole still needs the oracle on Aave v4, because the
    ///         Spoke's own partial `withdraw` prices every reserve flagged as collateral; the full
    ///         close, which clears the flag first, is the oracle-independent exit.
    function test_fork_shortEth_currentLtv_zeroDebt_doesNotPriceDuringOracleOutage() public {
        address account = router.accountOf(address(this), 0);
        _stageOpen(account);

        // clear the debt out of band: the owner repays it directly through the account
        (, uint256 debt) = adapter.positionOf(account, market);
        deal(WETH, account, debt + 1 ether);
        MarginAccount(payable(account)).repay(adapter, market, type(uint256).max);
        (uint256 collateral, uint256 debtAfter) = adapter.positionOf(account, market);
        assertEq(debtAfter, 0, "debt cleared");
        assertGt(collateral, 0, "collateral still supplied");

        vm.etch(EXPECTED_ORACLE, hex"60006000fd");
        ISpoke spoke = ISpoke(MAIN_SPOKE);
        vm.expectRevert();
        spoke.getUserAccountData(account);

        assertEq(Ltv.unwrap(adapter.currentLtvWad(account, market)), 0, "zero LTV without pricing");
    }

    // -------------------------------------------------------------------------
    // Lifecycle stages (split to keep locals-per-frame low: tests compile without via_ir)
    // -------------------------------------------------------------------------

    /// @notice Open a ~2x short: 2000 USDC equity buys 2000 USDC of collateral funded by borrowed WETH,
    ///         landing collateral at ~4000 USDC. Debt is positive WETH, within the maxDebtIn cap, and
    ///         the position is healthy. The settle proof: neither the account nor the router holds any
    ///         loose USDC or WETH afterward.
    function _stageOpen(address account) internal {
        // pre-fund the account with 2000 USDC equity; equity=0 in params avoids the Permit2 pull
        deal(USDC, account, 2000e6);
        _openCall(2000e6, _maxDebtForUsdc(2000e6));

        (uint256 collateral, uint256 debt) = adapter.positionOf(account, market);
        _log("open", account);
        assertApproxEqAbs(collateral, 4000e6, 1e6, "open: collateral = equity + bought");
        assertGt(debt, 0, "open: WETH debt drawn against the real Aave v4 market");

        // the live Spoke position must agree with the adapter read; the supply must be enabled as
        // collateral (otherwise the borrow's health check would have reverted)
        assertApproxEqAbs(
            ISpoke(MAIN_SPOKE).getUserSuppliedAssets(USDC_RESERVE_ID, account),
            collateral,
            1,
            "open: supplied == collateral"
        );
        assertEq(ISpoke(MAIN_SPOKE).getUserTotalDebt(WETH_RESERVE_ID, account), debt, "open: spoke debt == debt");

        // healthy: LTV positive and below the collateral's factor
        Ltv current = adapter.currentLtvWad(account, market);
        assertGt(Ltv.unwrap(current), 0, "open: ltv positive");
        assertLt(Ltv.unwrap(current), Ltv.unwrap(adapter.maxLtvWad(market)), "open: ltv under max");

        // describePosition returns the same values as the individual getters, in a single call
        PositionData memory snapshot = adapter.describePosition(account, market);
        assertEq(snapshot.collateralAmount, collateral, "describe: collateral matches positionOf");
        assertEq(snapshot.debtAmount, debt, "describe: debt matches positionOf");
        assertEq(Ltv.unwrap(snapshot.currentLtv), Ltv.unwrap(current), "describe: currentLtv matches");
        assertEq(Ltv.unwrap(snapshot.maxLtv), Ltv.unwrap(adapter.maxLtvWad(market)), "describe: maxLtv matches");
        assertGt(snapshot.healthFactorWad, 1e18, "describe: healthy position has HF > 1");

        _assertNoDust(account);
    }

    /// @notice Warp a day and prove the WETH debt grew purely from live Aave v4 accrual.
    function _stageAccrueInterest(address account) internal {
        uint256 debtBefore = ISpoke(MAIN_SPOKE).getUserTotalDebt(WETH_RESERVE_ID, account);
        vm.warp(block.timestamp + 1 days);
        uint256 debtAfter = ISpoke(MAIN_SPOKE).getUserTotalDebt(WETH_RESERVE_ID, account);
        _log("after 1d accrual", account);
        assertGt(debtAfter, debtBefore, "accrual: WETH debt grew from real interest");
    }

    /// @notice Partially delever: repay a fraction of the WETH debt by selling USDC collateral. Debt
    ///         and collateral both shrink but stay positive, and the resulting LTV passes the bound.
    function _stageDecrease(address account) internal {
        (uint256 collBefore, uint256 debtBefore) = adapter.positionOf(account, market);

        // repay a quarter of the current WETH debt; cap the USDC spent generously
        uint256 debtToRepay = debtBefore / 4;
        (bytes memory cmds, bytes[] memory ins) =
            buildV4ExactOutRoute(poolKey, market.collateral, market.debt, uint128(debtToRepay), 2000e6, account);
        router.decreasePosition(
            IMarginRouter.DecreaseParams({
                adapter: adapter,
                market: market,
                debtToRepay: debtToRepay,
                maxCollateralIn: 2000e6,
                universalRouter: ur,
                routeCommands: cmds,
                routeInputs: ins,
                maxLtvAfter: toLtv(0.7e18),
                subId: 0,
                deadline: block.timestamp + 1 hours
            })
        );

        (uint256 collAfter, uint256 debtAfter) = adapter.positionOf(account, market);
        _log("decrease", account);
        assertLt(debtAfter, debtBefore, "decrease: WETH debt reduced");
        assertGt(debtAfter, 0, "decrease: position still open");
        assertLt(collAfter, collBefore, "decrease: USDC collateral sold to fund repay");
        assertGt(collAfter, 0, "decrease: collateral remains");

        Ltv current = adapter.currentLtvWad(account, market);
        assertGt(Ltv.unwrap(current), 0, "decrease: ltv positive");
        assertLt(Ltv.unwrap(current), Ltv.unwrap(adapter.maxLtvWad(market)), "decrease: ltv under max");

        _assertNoDust(account);
    }

    /// @notice Full unwind: sell USDC collateral to buy back the full WETH debt, repay it with the
    ///         max-repay path, withdraw all USDC collateral (delivered to the account by the Spoke and
    ///         forwarded to the router), and return the residual USDC to the caller. Asserts the live
    ///         Spoke debt and supply both hit exactly zero and a positive residual is returned.
    function _stageClose(address account) internal {
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));

        (, uint256 curDebt) = adapter.positionOf(account, market);
        (bytes memory cmds, bytes[] memory ins) =
            buildV4ExactOutRoute(poolKey, market.collateral, market.debt, uint128(curDebt), 6000e6, account);
        router.decreasePosition(
            IMarginRouter.DecreaseParams({
                debtToRepay: type(uint256).max,
                maxLtvAfter: Ltv.wrap(0),
                adapter: adapter,
                market: market,
                maxCollateralIn: 6000e6,
                universalRouter: ur,
                routeCommands: cmds,
                routeInputs: ins,
                subId: 0,
                deadline: block.timestamp + 1 hours
            })
        );

        uint256 residual = IERC20(USDC).balanceOf(address(this)) - usdcBefore;
        _log("close", account);
        console2.log("residual USDC returned:", residual);

        assertEq(ISpoke(MAIN_SPOKE).getUserTotalDebt(WETH_RESERVE_ID, account), 0, "close: WETH debt fully repaid");
        assertEq(
            ISpoke(MAIN_SPOKE).getUserSuppliedAssets(USDC_RESERVE_ID, account),
            0,
            "close: all USDC collateral withdrawn"
        );

        (uint256 collateral, uint256 debt) = adapter.positionOf(account, market);
        assertEq(debt, 0, "close: adapter agrees debt is zero");
        assertEq(collateral, 0, "close: adapter agrees collateral is zero");

        assertGt(residual, 0, "close: residual USDC returned to caller");
        _assertNoDust(account);
    }

    // -------------------------------------------------------------------------
    // Thin router-call wrappers (isolate inline param-struct construction in their own frames)
    // -------------------------------------------------------------------------

    /// @notice Builds and submits an open buying `buy` USDC of collateral, capped at `maxDebtIn` WETH.
    function _openCall(uint128 buy, uint128 maxDebtIn) internal {
        address account = router.accountOf(address(this), 0);
        (bytes memory cmds, bytes[] memory ins) =
            buildV4ExactOutRoute(poolKey, market.debt, market.collateral, buy, maxDebtIn, account);
        router.increasePosition(
            IMarginRouter.IncreaseParams({
                adapter: adapter,
                market: market,
                equity: 0,
                collateralToBuy: buy,
                maxDebtIn: maxDebtIn,
                universalRouter: ur,
                routeCommands: cmds,
                routeInputs: ins,
                maxLtvAfter: Ltv.wrap(0),
                subId: 0,
                deadline: block.timestamp + 1 hours
            })
        );
    }

    /// @notice Funds the account with 2000 USDC of equity and opens the short through the native-pool
    ///         WETH route, sending the wrapped change to `changeTo`.
    function _openViaNativeRoute(uint256 subId, address account, address changeTo) internal {
        deal(USDC, account, 2000e6);
        uint128 maxDebtIn = _maxDebtForUsdc(2000e6);
        (bytes memory cmds, bytes[] memory ins) = _nativeWethRoute(2000e6, maxDebtIn, account, changeTo);
        router.increasePosition(
            IMarginRouter.IncreaseParams({
                adapter: adapter,
                market: market,
                equity: 0,
                collateralToBuy: 2000e6,
                maxDebtIn: maxDebtIn,
                universalRouter: ur,
                routeCommands: cmds,
                routeInputs: ins,
                maxLtvAfter: Ltv.wrap(0),
                subId: subId,
                deadline: block.timestamp + 1 hours
            })
        );
    }

    /// @notice Universal Router commands for a WETH-denominated exact-output buy through the native
    ///         pool: pull the cap as WETH into the Universal Router, unwrap it, settle the native swap
    ///         from the Universal Router's balance and take the USDC to `outputTo`, then wrap the
    ///         remaining ETH back to WETH for `changeTo`.
    function _nativeWethRoute(uint128 amountOut, uint128 maxIn, address outputTo, address changeTo)
        internal
        view
        returns (bytes memory commands, bytes[] memory inputs)
    {
        bytes memory v4Actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_OUT_SINGLE), uint8(Actions.SETTLE), uint8(Actions.TAKE));
        bytes[] memory v4Params = new bytes[](3);
        v4Params[0] = abi.encode(
            IV4Router.ExactOutputSingleParams({
                poolKey: nativePoolKey,
                zeroForOne: true,
                amountOut: amountOut,
                amountInMaximum: maxIn,
                minHopPriceX36: 0,
                hookData: ""
            })
        );
        v4Params[1] = abi.encode(Currency.wrap(address(0)), uint256(ActionConstants.OPEN_DELTA), false);
        v4Params[2] = abi.encode(Currency.wrap(USDC), outputTo, uint256(ActionConstants.OPEN_DELTA));

        commands = abi.encodePacked(
            uint8(Commands.PERMIT2_TRANSFER_FROM),
            uint8(Commands.UNWRAP_WETH),
            uint8(Commands.V4_SWAP),
            uint8(Commands.WRAP_ETH)
        );
        inputs = new bytes[](4);
        inputs[0] = abi.encode(WETH, ActionConstants.ADDRESS_THIS, uint160(maxIn));
        inputs[1] = abi.encode(ActionConstants.ADDRESS_THIS, uint256(0));
        inputs[2] = abi.encode(v4Actions, v4Params);
        inputs[3] = abi.encode(changeTo, ActionConstants.CONTRACT_BALANCE);
    }

    /// @notice The position borrowed roughly the oracle WETH cost of 2000 USDC (not the cap), and
    ///         neither the account, the router, nor the Universal Router holds loose WETH or ETH.
    function _assertBorrowedActualCost(address account, uint128 maxDebtIn) internal view {
        uint256 debt = ISpoke(MAIN_SPOKE).getUserTotalDebt(WETH_RESERVE_ID, account);
        uint256 oracleCost = FullMath.mulDiv(2000e6 * 1e12, usdcPriceBase, wethPriceBase);
        assertLt(debt, maxDebtIn, "borrowed less than the cap");
        assertApproxEqRel(debt, oracleCost, 0.02e18, "borrowed the real cost of the swap");
        _assertNoDust(account);
        assertEq(IERC20(WETH).balanceOf(ur), 0, "Universal Router holds no WETH");
        assertEq(ur.balance, 0, "Universal Router holds no ETH");
    }

    // -------------------------------------------------------------------------
    // Setup + verification helpers
    // -------------------------------------------------------------------------

    /// @notice Initializes a native ETH/USDC pool at the live Aave oracle price with deep full-range
    ///         liquidity, so a WETH-denominated route can swap natively.
    function _initAndSeedNativePool() internal {
        nativePoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(USDC),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        // price = USDC_raw per wei = (wethPrice / 1e18) / (usdcPrice / 1e6)
        uint256 priceX192 = FullMath.mulDiv(wethPriceBase, uint256(1) << 192, usdcPriceBase * 1e12);
        manager.initialize(nativePoolKey, uint160(FixedPointMathLib.sqrt(priceX192)));

        vm.deal(address(this), 200_000 ether);
        lpRouter.modifyLiquidity{value: 100_000 ether}(
            nativePoolKey,
            ModifyLiquidityParams({tickLower: MIN_TICK, tickUpper: MAX_TICK, liquidityDelta: 1e18, salt: 0}),
            ""
        );
    }

    /// @notice Deploys the adapter against the live Main Spoke and verifies on-chain that the WETH and
    ///         USDC reserves resolve to the expected underlyings on the Core Hub, the oracle matches,
    ///         and `maxLtvWad` decodes the USDC collateral factor. Probes that the short market key
    ///         routes with no registration step.
    function _deployAndVerifyAdapter() internal {
        adapter = new AaveV4LendingAdapter(ISpoke(MAIN_SPOKE));
        assertEq(adapter.lendingProtocol(), MAIN_SPOKE, "lendingProtocol == Main Spoke");
        assertEq(ISpoke(MAIN_SPOKE).ORACLE(), EXPECTED_ORACLE, "spoke oracle");

        ISpoke.Reserve memory wethReserve = ISpoke(MAIN_SPOKE).getReserve(WETH_RESERVE_ID);
        ISpoke.Reserve memory usdcReserve = ISpoke(MAIN_SPOKE).getReserve(USDC_RESERVE_ID);
        assertEq(wethReserve.underlying, WETH, "reserve 0 underlying == WETH");
        assertEq(usdcReserve.underlying, USDC, "reserve 7 underlying == USDC");
        assertEq(wethReserve.hub, CORE_HUB, "WETH reserve on Core Hub");
        assertEq(usdcReserve.hub, CORE_HUB, "USDC reserve on Core Hub");

        // the short needs borrowable WETH and usable USDC collateral
        assertTrue(ISpoke(MAIN_SPOKE).getReserveConfig(WETH_RESERVE_ID).borrowable, "WETH borrowable");
        assertFalse(ISpoke(MAIN_SPOKE).getReserveConfig(USDC_RESERVE_ID).paused, "USDC not paused");

        // market selection is permissionless: the live key routes with no registration step
        assertTrue(adapter.isSupportedMarket(market), "live USDC/WETH key is routable");

        // maxLtvWad must decode the USDC collateral factor (78%)
        assertEq(Ltv.unwrap(adapter.maxLtvWad(market)), USDC_CF_BPS * WAD / BPS, "maxLtvWad uses collateral factor");
        assertEq(Ltv.unwrap(adapter.maxLtvWad(market)), 0.78e18, "maxLtvWad == 0.78e18");
    }

    /// @notice Reads the live Aave v4 oracle prices for the WETH and USDC reserves (USD base, 8
    ///         decimals). The v4 oracle is reserveId-keyed, not asset-keyed.
    function _readOraclePrices() internal {
        IAaveOracle oracle = IAaveOracle(ISpoke(MAIN_SPOKE).ORACLE());
        assertEq(oracle.decimals(), 8, "oracle base decimals == 8");
        usdcPriceBase = oracle.getReservePrice(USDC_RESERVE_ID);
        wethPriceBase = oracle.getReservePrice(WETH_RESERVE_ID);
        assertGt(usdcPriceBase, 0, "USDC oracle price positive");
        assertGt(wethPriceBase, 0, "WETH oracle price positive");
        console2.log("oracle USDC price (8d):", usdcPriceBase);
        console2.log("oracle WETH price (8d):", wethPriceBase);
    }

    /// @notice Initializes the USDC/WETH pool at the live Aave oracle price and seeds deep full-range
    ///         liquidity using dealt tokens, so the swap leg values WETH the same way Aave does.
    function _initAndSeedPool() internal {
        // USDC (0xA0..) sorts below WETH (0xC0..), so currency0 = USDC, currency1 = WETH
        require(USDC < WETH, "currency ordering");
        poolKey = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(WETH),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        manager.initialize(poolKey, _sqrtPriceX96FromOracle());

        // deal generously and seed a large full-range position: depth far exceeds the few-thousand-USDC
        // swaps the lifecycle performs
        deal(USDC, address(this), 100_000_000_000e6);
        deal(WETH, address(this), 1_000_000 ether);
        IERC20(USDC).approve(address(lpRouter), type(uint256).max);
        IERC20(WETH).approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: MIN_TICK, tickUpper: MAX_TICK, liquidityDelta: 1e18, salt: 0}),
            ""
        );
    }

    /// @notice The sqrtPriceX96 for the USDC/WETH pool derived from the live Aave oracle. The v4 price
    ///         is token1/token0 = WETH_raw/USDC_raw. One USDC_raw (1e6) is worth `usdcPriceBase` USD;
    ///         one WETH_raw (1e18) is worth `wethPriceBase` USD. So the WETH_raw value-equal to one
    ///         USDC_raw is `usdcPriceBase * 1e12 / wethPriceBase`. sqrtPriceX96 = sqrt(v4price * 2^192).
    function _sqrtPriceX96FromOracle() internal view returns (uint160 sqrtPriceX96) {
        uint256 numerator = usdcPriceBase * 1e12;
        uint256 priceX192 = FullMath.mulDiv(numerator, uint256(1) << 192, wethPriceBase);
        sqrtPriceX96 = uint160(FixedPointMathLib.sqrt(priceX192));
        require(sqrtPriceX96 > TickMath.MIN_SQRT_PRICE && sqrtPriceX96 < TickMath.MAX_SQRT_PRICE, "price bounds");
    }

    /// @notice A generous WETH `maxDebtIn` cap for buying `usdcAmount` of USDC collateral: the oracle
    ///         WETH cost of that USDC plus a 10% slippage/fee buffer.
    function _maxDebtForUsdc(uint256 usdcAmount) internal view returns (uint128) {
        uint256 wethCost = FullMath.mulDiv(usdcAmount * 1e12, usdcPriceBase, wethPriceBase);
        return uint128(wethCost * 110 / 100);
    }

    // -------------------------------------------------------------------------
    // Assertion + logging helpers
    // -------------------------------------------------------------------------

    /// @notice Asserts neither the account nor the router retains loose USDC or WETH.
    function _assertNoDust(address account) internal view {
        assertEq(IERC20(USDC).balanceOf(account), 0, "account holds no loose USDC");
        assertEq(IERC20(WETH).balanceOf(account), 0, "account holds no loose WETH");
        assertEq(IERC20(USDC).balanceOf(address(router)), 0, "router holds no loose USDC");
        assertEq(IERC20(WETH).balanceOf(address(router)), 0, "router holds no loose WETH");
    }

    /// @notice Logs the position's collateral, debt, and current LTV at a lifecycle stage.
    function _log(string memory stage, address account) internal view {
        (uint256 collateral, uint256 debt) = adapter.positionOf(account, market);
        console2.log(stage);
        console2.log("  collateral (USDC):", collateral);
        console2.log("  debt (WETH wei):", debt);
        console2.log("  ltv (WAD):", Ltv.unwrap(adapter.currentLtvWad(account, market)));
    }
}
