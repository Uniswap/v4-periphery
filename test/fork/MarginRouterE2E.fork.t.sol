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
import {Market} from "../../src/types/Market.sol";
import {Ltv, toLtv} from "../../src/types/Ltv.sol";

/// @notice Full-stack end-to-end test of the margin suite in composition, on a mainnet fork.
///         Unlike the unit and mock-integration suites that prove each component in isolation, this
///         drives the entire stack at once over a complete position lifecycle:
///
///         MarginRouter (unlock + flash accounting + delta resolution)
///           -> V4Router swap through a real PoolManager
///           -> MorphoLendingAdapter encodes real Morpho Blue calls
///           -> MarginAccount executes them as itself on the real Morpho Blue WETH/USDC market
///           -> real AdaptiveCurveIRM interest accrual
///
///         The lending leg, equity tokens (WETH/USDC), Permit2, and WETH9 are all the live mainnet
///         contracts. The only locally-deployed venue is the v4 pool, which is seeded with deep
///         liquidity at the live Morpho oracle price so the swap leg and the lending leg agree on
///         valuation. The PoolManager code itself is the real audited v4-core contract.
///
///         Lifecycle exercised in one transaction stream: open (equity via Permit2) -> addCollateral
///         (native ETH) -> increase (pure leverage) -> accrue interest -> decrease (partial delever)
///         -> close (full unwind, residual PnL returned).
contract MarginRouterE2EForkTest is Test {
    using MarketParamsLib for MarketParams;

    // verified on mainnet (see setUp assertions / canonical registries)
    IMorpho internal constant MORPHO = IMorpho(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant ORACLE = 0xdC6fd5831277c693b1054e19E94047cB37c77615;
    address internal constant IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    // canonical Permit2, identical address on every chain
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint256 internal constant LLTV = 0.86e18;
    uint256 internal constant FORK_BLOCK = 25_319_047;

    // full range for tickSpacing 60 (matches the shared routing helpers)
    int24 internal constant MIN_TICK = -887_220;
    int24 internal constant MAX_TICK = 887_220;
    uint24 internal constant POOL_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;

    PoolManager internal manager;
    PoolModifyLiquidityTest internal lpRouter;
    MorphoLendingAdapter internal adapter;
    MarginRouter internal router;

    MarketParams internal marketParams;
    Market internal market;
    PoolKey internal poolKey;

    // bystander position snapshots, kept in storage so the multi-borrower flow can record/compare
    // across many steps without piling locals onto one stack frame (tests compile without via_ir)
    mapping(address account => uint256 collateral) internal _heldColl;
    mapping(address account => uint256 debt) internal _heldDebt;

    /// @dev Accept ETH: PoolModifyLiquidityTest refunds leftover native dust to the caller, and the
    ///      native add-collateral path is funded from this contract's balance.
    receive() external payable {}

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        vm.skip(bytes(rpc).length == 0);
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, FORK_BLOCK);

        // the real Morpho Blue WETH/USDC market: WETH collateral, USDC debt
        marketParams = MarketParams({loanToken: USDC, collateralToken: WETH, oracle: ORACLE, irm: IRM, lltv: LLTV});
        market = Market({collateral: Currency.wrap(WETH), debt: Currency.wrap(USDC)});

        // confirm the live contracts are what we expect rather than trusting the constants blindly
        assertEq(MORPHO.idToMarketParams(marketParams.id()).collateralToken, WETH, "market collateral");
        assertEq(MORPHO.idToMarketParams(marketParams.id()).loanToken, USDC, "market loan token");
        assertGt(PERMIT2.code.length, 0, "permit2 deployed");
        assertGt(WETH.code.length, 0, "weth deployed");

        // a real, freshly-deployed v4 PoolManager and a USDC/WETH pool priced at the Morpho oracle
        manager = new PoolManager(address(this));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        _initAndSeedPool();

        // the full margin stack, wired to the live Morpho, Permit2, and WETH9
        adapter = new MorphoLendingAdapter(MORPHO, address(this));
        adapter.setMarket(marketParams);

        address impl = address(new MarginAccount());
        router = new MarginRouter(
            IPoolManager(address(manager)), IAllowanceTransfer(PERMIT2), IWETH9(WETH), impl, address(this)
        );
        router.setAdapterAllowed(adapter, true);
    }

    /// @notice Proves the entire stack composes across a full position lifecycle against live Morpho.
    ///         Each stage reads and asserts the real position state through the adapter, so the
    ///         assertions themselves exercise the read path on the live market.
    function test_fork_e2e_fullLifecycle() public {
        address account = router.accountOf(address(this), 0);

        _stageOpen(account);
        _stageAddCollateral(account);
        _stageIncrease(account);
        _stageAccrueInterest(account);
        _stageDecrease(account);
        _stageClose(account);
    }

    /// @notice Proves the stack stays correct with several independent borrowers contending for the
    ///         same Morpho market and the same v4 pool at once. This is the non-trivial path: three
    ///         positions are opened interleaved (two distinct owners, one of whom runs two
    ///         sub-accounts), they accrue interest together for a week, one borrower levers up while
    ///         the others are open, and they are closed in a different order than they were opened.
    ///         Throughout, each borrower's position must remain isolated: another borrower's open,
    ///         increase, or close must never move my collateral, and may only touch my debt within
    ///         share-rounding. Each owner receives their own residual PnL; the router never retains
    ///         dust.
    function test_fork_e2e_multipleBorrowers() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        // top up the lender side of the real market so it can fund several borrowers at once. this
        // is an ordinary Morpho supply by an external lender; the market and its accounting stay real.
        _seedMorphoLiquidity(5_000_000e6);

        // interleaved opens against the shared market + pool. alice/0 via Permit2; bob via native ETH
        // (larger, ~0.6 LTV); alice/1 is a second, independent sub-account of the same owner.
        address aliceAcct0 = _openPermit2(alice, 0, 1 ether, 1 ether);
        address bobAcct = _openNative(bob, 0, 2 ether, 3 ether);
        address aliceAcct1 = _openPermit2(alice, 1, 1 ether, 2 ether);

        // (owner, subId) addressing yields three distinct, non-overlapping accounts
        assertTrue(aliceAcct0 != bobAcct, "alice/0 != bob");
        assertTrue(aliceAcct0 != aliceAcct1, "alice/0 != alice/1");
        assertTrue(bobAcct != aliceAcct1, "bob != alice/1");

        _assertOpenHealthy(aliceAcct0, 2 ether);
        _assertOpenHealthy(bobAcct, 5 ether);
        _assertOpenHealthy(aliceAcct1, 3 ether);
        _assertNoDustRouter();

        // a week passes: every borrower's debt grows from the one shared interest-rate model
        _recordHeld(aliceAcct0);
        _recordHeld(bobAcct);
        _recordHeld(aliceAcct1);
        vm.warp(block.timestamp + 7 days);
        _assertDebtGrew(aliceAcct0);
        _assertDebtGrew(bobAcct);
        _assertDebtGrew(aliceAcct1);

        // bob levers up further (to ~0.71 LTV) while alice's two positions are open; alice untouched
        _recordHeld(aliceAcct0);
        _recordHeld(aliceAcct1);
        _increaseFor(bob, 0, 2 ether);
        _assertHealthy(bobAcct);
        _assertStillHeld(aliceAcct0);
        _assertStillHeld(aliceAcct1);
        _assertNoDustRouter();

        // close out of order: alice/0 first, then bob, then alice/1. each close fully unwinds its own
        // account and leaves every still-open account's collateral exact and debt within rounding.
        _recordHeld(bobAcct);
        _recordHeld(aliceAcct1);
        _closeAndZero(alice, 0, aliceAcct0);
        _assertStillHeld(bobAcct);
        _assertStillHeld(aliceAcct1);

        _recordHeld(aliceAcct1);
        _closeAndZero(bob, 0, bobAcct);
        _assertStillHeld(aliceAcct1);

        _closeAndZero(alice, 1, aliceAcct1);
        _assertNoDustRouter();
    }

    // -------------------------------------------------------------------------
    // Lifecycle stages (split to keep locals-per-frame low: tests compile without via_ir)
    // -------------------------------------------------------------------------

    /// @notice Open a ~2x long: 1 WETH equity supplied via real Permit2, lever to ~2 WETH collateral.
    function _stageOpen(address account) internal {
        _approvePermit2Equity(1 ether);
        _openCall(1 ether, 1 ether);

        (uint256 collateral, uint256 debt) = adapter.positionOf(account, market);
        _log("open", account);
        assertApproxEqAbs(collateral, 2 ether, 1, "open: collateral = equity + bought");
        assertGt(debt, 0, "open: debt drawn against the real market");
        _assertHealthy(account);
        _assertNoDust(account);
    }

    /// @notice Add 0.5 WETH of native ETH equity (router wraps it); debt unchanged, LTV falls.
    function _stageAddCollateral(address account) internal {
        (uint256 collBefore, uint256 debtBefore) = adapter.positionOf(account, market);
        uint256 ltvBefore = Ltv.unwrap(adapter.currentLtvWad(account, market));

        vm.deal(address(this), 0.5 ether);
        router.addCollateral{value: 0.5 ether}(
            IMarginRouter.AddCollateralParams({
                adapter: adapter, market: market, amount: 0, subId: 0, deadline: block.timestamp + 1 hours
            })
        );

        (uint256 collAfter, uint256 debtAfter) = adapter.positionOf(account, market);
        _log("addCollateral", account);
        assertApproxEqAbs(collAfter, collBefore + 0.5 ether, 1, "addCollateral: collateral grew by deposit");
        assertApproxEqAbs(debtAfter, debtBefore, 1, "addCollateral: debt unchanged");
        assertLt(Ltv.unwrap(adapter.currentLtvWad(account, market)), ltvBefore, "addCollateral: ltv fell");
        _assertNoDust(account);
    }

    /// @notice Buy +1 WETH of leverage with no new equity (debt-funded); collateral and debt grow.
    function _stageIncrease(address account) internal {
        (uint256 collBefore, uint256 debtBefore) = adapter.positionOf(account, market);

        _increaseCall(1 ether);

        (uint256 collAfter, uint256 debtAfter) = adapter.positionOf(account, market);
        _log("increase", account);
        assertApproxEqAbs(collAfter, collBefore + 1 ether, 1, "increase: collateral grew by bought");
        assertGt(debtAfter, debtBefore, "increase: debt grew");
        _assertHealthy(account);
        _assertNoDust(account);
    }

    /// @notice Warp a day and prove debt grew purely from the live AdaptiveCurveIRM accrual.
    function _stageAccrueInterest(address account) internal {
        (, uint256 debtBefore) = adapter.positionOf(account, market);
        vm.warp(block.timestamp + 1 days);
        (, uint256 debtAfter) = adapter.positionOf(account, market);
        _log("after 1d accrual", account);
        assertGt(debtAfter, debtBefore, "accrual: debt grew from real interest");
    }

    /// @notice Partially delever: repay 1000 USDC by selling collateral; position stays open, bounded.
    function _stageDecrease(address account) internal {
        (uint256 collBefore, uint256 debtBefore) = adapter.positionOf(account, market);

        router.decreasePosition(
            IMarginRouter.DecreaseParams({
                adapter: adapter,
                market: market,
                poolKey: poolKey,
                debtToRepay: 1000e6,
                maxCollateralIn: 2 ether,
                minHopPriceX36: 0,
                maxLtvAfter: toLtv(0.7e18),
                subId: 0,
                deadline: block.timestamp + 1 hours
            })
        );

        (uint256 collAfter, uint256 debtAfter) = adapter.positionOf(account, market);
        _log("decrease", account);
        assertLt(debtAfter, debtBefore, "decrease: debt reduced");
        assertGt(debtAfter, 0, "decrease: position still open");
        assertLt(collAfter, collBefore, "decrease: collateral sold to fund repay");
        assertGt(collAfter, 0, "decrease: collateral remains");
        _assertHealthy(account);
        _assertNoDust(account);
    }

    /// @notice Full unwind: repay all debt by shares, withdraw all collateral, return residual PnL.
    function _stageClose(address account) internal {
        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));

        router.closePosition(
            IMarginRouter.CloseParams({
                adapter: adapter,
                market: market,
                poolKey: poolKey,
                maxCollateralIn: 5 ether,
                minHopPriceX36: 0,
                subId: 0,
                deadline: block.timestamp + 1 hours
            })
        );

        (uint256 collateral, uint256 debt) = adapter.positionOf(account, market);
        uint256 residual = IERC20(WETH).balanceOf(address(this)) - wethBefore;
        _log("close", account);
        console2.log("residual WETH returned:", residual);

        assertEq(debt, 0, "close: debt fully repaid by shares on the real market");
        assertEq(collateral, 0, "close: all collateral withdrawn");
        // net equity contributed was 1.5 WETH; residual is that minus swap fees, slippage, and one
        // day of accrued interest, and is price-independent (pool == oracle price). Sanity-band it.
        assertGt(residual, 1.3 ether, "close: residual returns most of the equity");
        assertLt(residual, 1.5 ether, "close: residual below equity (costs were incurred)");
        _assertNoDust(account);
    }

    // -------------------------------------------------------------------------
    // Thin router-call wrappers (isolate inline param-struct construction in their own frames)
    // -------------------------------------------------------------------------

    /// @notice Builds and submits an open with `equity` WETH and `buy` WETH of collateral.
    function _openCall(uint256 equity, uint128 buy) internal {
        router.openPosition(
            IMarginRouter.OpenParams({
                adapter: adapter,
                market: market,
                poolKey: poolKey,
                equity: equity,
                collateralToBuy: buy,
                maxDebtIn: 10_000e6,
                minHopPriceX36: 0,
                subId: 0,
                deadline: block.timestamp + 1 hours
            })
        );
    }

    /// @notice Builds and submits a pure-leverage increase buying `buy` WETH with no new equity.
    function _increaseCall(uint128 buy) internal {
        router.increasePosition(
            IMarginRouter.OpenParams({
                adapter: adapter,
                market: market,
                poolKey: poolKey,
                equity: 0,
                collateralToBuy: buy,
                maxDebtIn: 10_000e6,
                minHopPriceX36: 0,
                subId: 0,
                deadline: block.timestamp + 1 hours
            })
        );
    }

    // -------------------------------------------------------------------------
    // Setup + assertion helpers
    // -------------------------------------------------------------------------

    /// @notice Initializes the USDC/WETH pool at the live oracle price and seeds deep full-range
    ///         liquidity using dealt tokens, so the swap leg values WETH the same way Morpho does.
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

        // Morpho oracle: USDC_raw = WETH_raw * price / 1e36. The v4 price is token1/token0 =
        // WETH_raw/USDC_raw = 1e36 / price. sqrtPriceX96 = sqrt(v4price * 2^192).
        uint256 oraclePrice = IOracle(ORACLE).price();
        uint256 priceX192 = FullMath.mulDiv(1e36, uint256(1) << 192, oraclePrice);
        uint160 sqrtPriceX96 = uint160(FixedPointMathLib.sqrt(priceX192));
        require(sqrtPriceX96 > TickMath.MIN_SQRT_PRICE && sqrtPriceX96 < TickMath.MAX_SQRT_PRICE, "price bounds");

        manager.initialize(poolKey, sqrtPriceX96);

        // deal generously (covers any plausible WETH price at the fork block) and seed a large
        // full-range position: depth far exceeds the few-WETH swaps the lifecycle performs
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

    /// @notice Grants the router a Permit2 allowance to pull `amount` of WETH equity from this test.
    function _approvePermit2Equity(uint256 amount) internal {
        IERC20(WETH).approve(PERMIT2, type(uint256).max);
        IAllowanceTransfer(PERMIT2).approve(WETH, address(router), uint160(amount), uint48(block.timestamp + 1 hours));
    }

    /// @notice Asserts the position is below the market's max LTV (not liquidatable).
    function _assertHealthy(address account) internal view {
        Ltv current = adapter.currentLtvWad(account, market);
        assertGt(Ltv.unwrap(current), 0, "ltv positive");
        assertLt(Ltv.unwrap(current), LLTV, "ltv under market max");
    }

    /// @notice Asserts neither the account nor the router retains loose collateral or debt tokens.
    function _assertNoDust(address account) internal view {
        assertEq(IERC20(WETH).balanceOf(account), 0, "account holds no loose WETH");
        assertEq(IERC20(USDC).balanceOf(account), 0, "account holds no loose USDC");
        _assertNoDustRouter();
    }

    /// @notice Asserts the router holds no loose collateral or debt tokens.
    function _assertNoDustRouter() internal view {
        assertEq(IERC20(WETH).balanceOf(address(router)), 0, "router holds no loose WETH");
        assertEq(IERC20(USDC).balanceOf(address(router)), 0, "router holds no loose USDC");
    }

    // -------------------------------------------------------------------------
    // Multi-borrower helpers (each pranks as the borrower; snapshots live in storage)
    // -------------------------------------------------------------------------

    /// @notice Supplies `assets` USDC to the real Morpho market as an external lender, expanding the
    ///         idle liquidity available for borrowers.
    function _seedMorphoLiquidity(uint256 assets) internal {
        address lender = makeAddr("lender");
        deal(USDC, lender, assets);
        vm.startPrank(lender);
        IERC20(USDC).approve(address(MORPHO), assets);
        MORPHO.supply(marketParams, assets, 0, lender, "");
        vm.stopPrank();
    }

    /// @notice Opens a position for `who` at `subId` with `equity` WETH supplied via real Permit2.
    function _openPermit2(address who, uint256 subId, uint256 equity, uint128 buy) internal returns (address account) {
        account = router.accountOf(who, subId);
        deal(WETH, who, equity);
        vm.startPrank(who);
        IERC20(WETH).approve(PERMIT2, type(uint256).max);
        IAllowanceTransfer(PERMIT2).approve(WETH, address(router), uint160(equity), uint48(block.timestamp + 1 hours));
        router.openPosition(_openParamsFor(subId, equity, buy));
        vm.stopPrank();
    }

    /// @notice Opens a position for `who` at `subId` with `equityEth` of native ETH as equity.
    function _openNative(address who, uint256 subId, uint256 equityEth, uint128 buy)
        internal
        returns (address account)
    {
        account = router.accountOf(who, subId);
        vm.deal(who, equityEth);
        vm.prank(who);
        router.openPosition{value: equityEth}(_openParamsFor(subId, 0, buy));
    }

    /// @notice Adds `buy` WETH of pure leverage (no new equity) to `who`'s position at `subId`.
    function _increaseFor(address who, uint256 subId, uint128 buy) internal {
        vm.prank(who);
        router.increasePosition(_openParamsFor(subId, 0, buy));
    }

    /// @notice Closes `who`'s position at `subId`, asserts it is fully unwound, and returns the
    ///         residual WETH (realized PnL) credited to the owner.
    function _closeAndZero(address who, uint256 subId, address account) internal returns (uint256 residual) {
        uint256 wethBefore = IERC20(WETH).balanceOf(who);
        vm.prank(who);
        router.closePosition(_closeParamsFor(subId));
        residual = IERC20(WETH).balanceOf(who) - wethBefore;

        (uint256 collateral, uint256 debt) = adapter.positionOf(account, market);
        assertEq(debt, 0, "closed: debt fully repaid");
        assertEq(collateral, 0, "closed: all collateral withdrawn");
        assertGt(residual, 0, "closed: residual returned to owner");
        _assertNoDust(account);
    }

    /// @notice Builds open/increase params for `subId` (generous bounds; size set by `equity`/`buy`).
    function _openParamsFor(uint256 subId, uint256 equity, uint128 buy)
        internal
        view
        returns (IMarginRouter.OpenParams memory)
    {
        return IMarginRouter.OpenParams({
            adapter: adapter,
            market: market,
            poolKey: poolKey,
            equity: equity,
            collateralToBuy: buy,
            maxDebtIn: 20_000e6,
            minHopPriceX36: 0,
            subId: subId,
            deadline: block.timestamp + 1 hours
        });
    }

    /// @notice Builds close params for `subId` with a generous collateral-in bound.
    function _closeParamsFor(uint256 subId) internal view returns (IMarginRouter.CloseParams memory) {
        return IMarginRouter.CloseParams({
            adapter: adapter,
            market: market,
            poolKey: poolKey,
            maxCollateralIn: 10 ether,
            minHopPriceX36: 0,
            subId: subId,
            deadline: block.timestamp + 1 hours
        });
    }

    /// @notice Asserts a freshly opened position has the expected collateral, positive debt, health.
    function _assertOpenHealthy(address account, uint256 expectedCollateral) internal view {
        (uint256 collateral, uint256 debt) = adapter.positionOf(account, market);
        assertApproxEqAbs(collateral, expectedCollateral, 1, "open: collateral = equity + bought");
        assertGt(debt, 0, "open: debt drawn against the shared market");
        _assertHealthy(account);
    }

    /// @notice Records a bystander account's current (collateral, debt) for later isolation checks.
    function _recordHeld(address account) internal {
        (uint256 collateral, uint256 debt) = adapter.positionOf(account, market);
        _heldColl[account] = collateral;
        _heldDebt[account] = debt;
    }

    /// @notice Asserts another borrower's action left this account isolated: collateral exactly
    ///         unchanged, debt within share-rounding of the recorded value, position still open.
    function _assertStillHeld(address account) internal view {
        (uint256 collateral, uint256 debt) = adapter.positionOf(account, market);
        assertEq(collateral, _heldColl[account], "bystander collateral must be untouched");
        assertApproxEqAbs(debt, _heldDebt[account], 100, "bystander debt only moves within rounding");
        assertGt(debt, 0, "bystander position still open");
    }

    /// @notice Asserts an account's debt strictly grew from its recorded value (shared accrual).
    function _assertDebtGrew(address account) internal view {
        (, uint256 debt) = adapter.positionOf(account, market);
        assertGt(debt, _heldDebt[account], "debt grew from real interest accrual");
    }

    /// @notice Logs the position's collateral, debt, and current LTV at a lifecycle stage.
    function _log(string memory stage, address account) internal view {
        (uint256 collateral, uint256 debt) = adapter.positionOf(account, market);
        console2.log(stage);
        console2.log("  collateral (WETH wei):", collateral);
        console2.log("  debt (USDC):", debt);
        console2.log("  ltv (WAD):", Ltv.unwrap(adapter.currentLtvWad(account, market)));
    }
}
