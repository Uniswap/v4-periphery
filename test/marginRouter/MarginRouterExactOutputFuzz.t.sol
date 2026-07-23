// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RoutingTestHelpers} from "../shared/RoutingTestHelpers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IWETH9} from "../../src/interfaces/external/IWETH9.sol";
import {IV4Router} from "../../src/interfaces/IV4Router.sol";
import {IMarginRouter} from "../../src/interfaces/IMarginRouter.sol";
import {MarginRouter} from "../../src/MarginRouter.sol";
import {MarginAccount} from "../../src/MarginAccount.sol";
import {Market} from "../../src/types/Market.sol";
import {Ltv, toLtv} from "../../src/types/Ltv.sol";
import {MockLendingAdapter} from "../mocks/MockLendingAdapter.sol";
import {MockLendingProtocol} from "../mocks/MockLendingProtocol.sol";

/// @notice Fuzz coverage for the exact-output partial-fill bug class caught in audit.
///
/// Two fixes are exercised:
///   Fix A (price guard on realized output): `_swapExactOutputSingle` computes the hop price
///          from the REALIZED output, not the requested amount. A bound exceeding the achievable
///          price reverts `V4TooMuchRequestedPerHopSingle`.
///   Fix C (ASSERT_FILL all-or-nothing): `_open` inserts `ASSERT_FILL` so an under-filled
///          exact-output swap reverts `IncompleteFill` before the take, rather than silently
///          opening a smaller position.
///
/// Pool geometry:
///   Deep pool  - full-range liquidity (200 ether in [-887220, 887220]) via key0 from the helper;
///                capable of fully filling any collateralToBuy in the tested range.
///   Thin pool  - liquidity in a single tick-spacing band [0, 60] with 200 ether. The band covers
///                a narrow price range; the regression test confirms a 1-ether exact-output buy
///                already exhausts it. Fuzz uses THIN_MIN_OVERFLOW_BUY = 1.1 ether as the floor.
///   Thin close - liquidity in band [-60, 0], symmetric to the open pool, used by close.
///
/// Price guard calibration (Fix A, Property 3b):
///   The realized price for an exact-output swap is `realizedOutput / amountIn`.  Due to integer
///   fee rounding in the pool, dust-level swaps (e.g. 1 wei) can exhibit large effective prices
///   (e.g. price = 1/3 when the minimum fee rounds amountIn to 3).  PRICE_GUARD_MIN_BUY (0.01
///   ether) is the lower bound used in Property 3b: at this scale fee rounding is negligible and
///   the price ratio is predictably ~0.997 for a 1:1 pool with 0.3% fee.  PRICE_GUARD_SAFE_MAX
///   (0.9e36) is the ceiling for the fuzzed bound, sitting safely below the worst-case realized
///   price of ~0.949 that occurs for the maximum 10-ether buy.
contract MarginRouterExactOutputFuzzTest is RoutingTestHelpers {
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    // Maximum collateralToBuy fuzzed against the deep pool.  200 ether liquidity at 1:1 can fill
    // up to ~95 ether before price impact becomes extreme; 10 ether keeps execution predictable.
    uint128 internal constant DEEP_MAX_BUY = 10 ether;

    // Generous debt cap.  At 10 ether buy with ~5.5% price impact the true cost is ~10.53 ether.
    // 12 ether leaves comfortable margin so the maxDebtIn check never fires on the success path.
    uint128 internal constant DEEP_MAX_DEBT = 12 ether;

    // Lower bound for collateralToBuy on the thin pool.  The regression test
    // (MarginRouterExactOutputShortFillTest) confirms 1 ether causes a partial fill; 1.1 ether
    // keeps the fuzz firmly above the band capacity with a safety margin.
    uint128 internal constant THIN_MIN_OVERFLOW_BUY = 1.1 ether;

    // Upper bound for the per-hop price floor in the "guard does not block" property (3b).
    // Worst-case realized price on the deep pool across [PRICE_GUARD_MIN_BUY, DEEP_MAX_BUY] is
    // ~0.949 (10-ether buy).  Capping the fuzzed bound at 0.9e36 ensures it is always below the
    // realized price for any buy in the tested range.
    uint256 internal constant PRICE_GUARD_SAFE_MAX = 0.9e36;

    // Lower bound for collateralToBuy in the price-guard property (3b).  Dust-level swaps (< 1e14)
    // can have distorted price ratios due to integer fee rounding in the pool.  At 0.01 ether the
    // rounding error is sub-basis-point and the realized price is stably ~0.997, above the
    // PRICE_GUARD_SAFE_MAX ceiling of 0.9.
    uint128 internal constant PRICE_GUARD_MIN_BUY = 0.01 ether;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    MarginRouter internal marginRouter;
    MockLendingAdapter internal adapter;
    MockLendingProtocol internal protocol;

    Market internal market;
    PoolKey internal deepPoolKey;
    PoolKey internal thinPoolKey;
    PoolKey internal thinClosePoolKey;

    Currency internal collateral;
    Currency internal debt;

    // -------------------------------------------------------------------------
    // setUp
    // -------------------------------------------------------------------------

    function setUp() public {
        setupRouterCurrenciesAndPoolsWithLiquidity();

        collateral = currency0;
        debt = currency1;
        market = Market({collateral: collateral, debt: debt});

        // key0 is the deep full-range (currency0, currency1, fee=3000) pool from the helper.
        deepPoolKey = key0;

        // Thin open pool: liquidity only in tick band [0, 60].  A buy that moves price upward
        // (selling debt, buying collateral) exhausts this band quickly for amounts >= 1.1 ether.
        thinPoolKey = _createThinPool(3001, 0, 60);

        // Thin close pool: liquidity only in tick band [-60, 0] for the close direction.
        thinClosePoolKey = _createThinPool(3002, -60, 0);

        protocol = new MockLendingProtocol(IERC20(Currency.unwrap(collateral)), IERC20(Currency.unwrap(debt)));
        adapter = new MockLendingAdapter(address(protocol));
        adapter.setSupported(market, true);

        address impl = address(new MarginAccount());
        marginRouter = new MarginRouter(
            manager, IAllowanceTransfer(address(0xdead)), IWETH9(address(0xbeef)), impl, address(this)
        );
        marginRouter.setAdapterAllowed(adapter, true);

        // Seed the lending protocol with enough debt liquidity to service any fuzzed borrow.
        MockERC20(Currency.unwrap(debt)).transfer(address(protocol), 1_000_000 ether);
    }

    // -------------------------------------------------------------------------
    // Property 1: Full-fill exactness on the deep pool.
    //
    // For any (collateralToBuy, equity) in range the open succeeds and the resulting collateral
    // position equals equity + collateralToBuy exactly (ASSERT_FILL guarantees the exact-output
    // swap delivered the full requested amount).  No loose tokens remain in the account or router.
    // -------------------------------------------------------------------------

    function testFuzz_increasePosition_deepPool_fullFillExact(uint128 collateralToBuy, uint128 equity) public {
        collateralToBuy = uint128(bound(collateralToBuy, 1, DEEP_MAX_BUY));
        equity = uint128(bound(equity, 0, 50 ether));

        address account = marginRouter.accountOf(address(this), 0);
        if (equity > 0) MockERC20(Currency.unwrap(collateral)).transfer(account, equity);

        marginRouter.increasePosition(
            IMarginRouter.IncreaseParams({
                adapter: adapter,
                market: market,
                poolKey: deepPoolKey,
                equity: 0, // equity already in account; avoid permit2
                collateralToBuy: collateralToBuy,
                maxDebtIn: DEEP_MAX_DEBT,
                minHopPriceX36: 0,
                maxLtvAfter: Ltv.wrap(0),
                subId: 0,
                deadline: block.timestamp + 1
            })
        );

        assertEq(
            protocol.collateralOf(account),
            uint256(equity) + uint256(collateralToBuy),
            "collateral = equity + collateralToBuy"
        );
        assertGt(protocol.debtOf(account), 0, "debt drawn");
        assertLe(protocol.debtOf(account), DEEP_MAX_DEBT, "debt within maxDebtIn");

        // No dust in account or router.
        assertEq(IERC20(Currency.unwrap(collateral)).balanceOf(account), 0, "account: no loose collateral");
        assertEq(IERC20(Currency.unwrap(debt)).balanceOf(account), 0, "account: no loose debt");
        assertEq(IERC20(Currency.unwrap(collateral)).balanceOf(address(marginRouter)), 0, "router: no loose collateral");
        assertEq(IERC20(Currency.unwrap(debt)).balanceOf(address(marginRouter)), 0, "router: no loose debt");
    }

    // -------------------------------------------------------------------------
    // Property 1b: The exactness guarantee holds across distinct sub-accounts (vary subId).
    // -------------------------------------------------------------------------

    function testFuzz_increasePosition_deepPool_fullFillExact_varySubId(uint128 collateralToBuy, uint256 subId) public {
        collateralToBuy = uint128(bound(collateralToBuy, 1, DEEP_MAX_BUY));
        subId = bound(subId, 0, 100);

        address account = marginRouter.accountOf(address(this), subId);
        MockERC20(Currency.unwrap(collateral)).transfer(account, 1 ether);

        marginRouter.increasePosition(
            IMarginRouter.IncreaseParams({
                adapter: adapter,
                market: market,
                poolKey: deepPoolKey,
                equity: 0,
                collateralToBuy: collateralToBuy,
                maxDebtIn: DEEP_MAX_DEBT,
                minHopPriceX36: 0,
                maxLtvAfter: Ltv.wrap(0),
                subId: subId,
                deadline: block.timestamp + 1
            })
        );

        assertEq(
            protocol.collateralOf(account), 1 ether + uint256(collateralToBuy), "collateral = equity + collateralToBuy"
        );
        assertEq(IERC20(Currency.unwrap(collateral)).balanceOf(account), 0, "account: no loose collateral");
        assertEq(IERC20(Currency.unwrap(debt)).balanceOf(account), 0, "account: no loose debt");
        assertEq(IERC20(Currency.unwrap(collateral)).balanceOf(address(marginRouter)), 0, "router: no loose collateral");
        assertEq(IERC20(Currency.unwrap(debt)).balanceOf(address(marginRouter)), 0, "router: no loose debt");
    }

    // -------------------------------------------------------------------------
    // Property 2: Partial fill reverts with IncompleteFill on the thin pool (Fix C).
    //
    // With a large enough collateralToBuy the single-band pool exhausts before delivering the full
    // output.  ASSERT_FILL detects the shortfall and reverts IncompleteFill before the take, so
    // no partial position is ever opened.
    // -------------------------------------------------------------------------

    function testFuzz_increasePosition_thinPool_revertsIncompleteFill(uint128 collateralToBuy) public {
        // 1.1 ether is comfortably above the band capacity (regression confirms 1 ether overflows).
        collateralToBuy = uint128(bound(collateralToBuy, THIN_MIN_OVERFLOW_BUY, DEEP_MAX_BUY));

        address account = marginRouter.accountOf(address(this), 0);
        MockERC20(Currency.unwrap(collateral)).transfer(account, 1 ether);

        vm.expectPartialRevert(IMarginRouter.IncompleteFill.selector);
        marginRouter.increasePosition(
            IMarginRouter.IncreaseParams({
                adapter: adapter,
                market: market,
                poolKey: thinPoolKey,
                equity: 0,
                collateralToBuy: collateralToBuy,
                maxDebtIn: DEEP_MAX_DEBT,
                minHopPriceX36: 0,
                maxLtvAfter: Ltv.wrap(0),
                subId: 0,
                deadline: block.timestamp + 1
            })
        );
    }

    // -------------------------------------------------------------------------
    // Property 3a: Price guard fires on a thin pool when minHopPriceX36 > achievable price (Fix A).
    //
    // After Fix A the guard compares against the REALIZED output (not the requested amount).  A
    // bound set above the achievable realized price causes V4TooMuchRequestedPerHopSingle before
    // ASSERT_FILL, giving a clear error rather than a silent under-fill.
    // -------------------------------------------------------------------------

    function testFuzz_increasePosition_thinPool_priceGuardRevertsWhenBoundTooHigh(uint128 collateralToBuy) public {
        collateralToBuy = uint128(bound(collateralToBuy, THIN_MIN_OVERFLOW_BUY, DEEP_MAX_BUY));

        address account = marginRouter.accountOf(address(this), 0);
        MockERC20(Currency.unwrap(collateral)).transfer(account, 1 ether);

        // 2.0 collateral-per-debt in X36 is far above the achievable ~1:1 ratio on this pool, so
        // the guard fires during the swap rather than waiting for ASSERT_FILL.
        uint256 unreachableMinHopPrice = 2e36;

        vm.expectPartialRevert(IV4Router.V4TooMuchRequestedPerHopSingle.selector);
        marginRouter.increasePosition(
            IMarginRouter.IncreaseParams({
                adapter: adapter,
                market: market,
                poolKey: thinPoolKey,
                equity: 0,
                collateralToBuy: collateralToBuy,
                maxDebtIn: DEEP_MAX_DEBT,
                minHopPriceX36: unreachableMinHopPrice,
                maxLtvAfter: Ltv.wrap(0),
                subId: 0,
                deadline: block.timestamp + 1
            })
        );
    }

    // -------------------------------------------------------------------------
    // Property 3b: Price guard does NOT block a successful deep-pool open when the bound is
    //              below the realized price.
    //
    // A fuzzed bound in [0, PRICE_GUARD_SAFE_MAX] is always <= the worst-case realized price on
    // the deep pool across [PRICE_GUARD_MIN_BUY, DEEP_MAX_BUY].  The lower bound on collateral
    // ensures fee-rounding is negligible and the realized price is stably above the safe ceiling.
    // -------------------------------------------------------------------------

    function testFuzz_increasePosition_deepPool_priceGuardDoesNotBlock(uint128 collateralToBuy, uint256 minHopPriceX36)
        public
    {
        // Use PRICE_GUARD_MIN_BUY (0.01 ether) as the floor: at this scale the 0.3% fee causes
        // < 0.1% rounding error, so price ~= 0.997, safely above PRICE_GUARD_SAFE_MAX (0.9).
        // Dust-level swaps (< 1e14) can have artificially low realized prices due to fee rounding.
        collateralToBuy = uint128(bound(collateralToBuy, PRICE_GUARD_MIN_BUY, DEEP_MAX_BUY));
        // PRICE_GUARD_SAFE_MAX (0.9e36) is below the worst-case realized price ~0.949 for a
        // 10-ether buy from the 200-ether pool, so any bound in [0, 0.9e36] lets the swap through.
        minHopPriceX36 = bound(minHopPriceX36, 0, PRICE_GUARD_SAFE_MAX);

        address account = marginRouter.accountOf(address(this), 0);
        MockERC20(Currency.unwrap(collateral)).transfer(account, 1 ether);

        marginRouter.increasePosition(
            IMarginRouter.IncreaseParams({
                adapter: adapter,
                market: market,
                poolKey: deepPoolKey,
                equity: 0,
                collateralToBuy: collateralToBuy,
                maxDebtIn: DEEP_MAX_DEBT,
                minHopPriceX36: minHopPriceX36,
                maxLtvAfter: Ltv.wrap(0),
                subId: 0,
                deadline: block.timestamp + 1
            })
        );

        assertEq(
            protocol.collateralOf(account), 1 ether + uint256(collateralToBuy), "collateral = equity + collateralToBuy"
        );
        assertEq(IERC20(Currency.unwrap(collateral)).balanceOf(address(marginRouter)), 0, "router: no loose collateral");
        assertEq(IERC20(Currency.unwrap(debt)).balanceOf(address(marginRouter)), 0, "router: no loose debt");
    }

    // -------------------------------------------------------------------------
    // Property 4: maxDebtIn below the true swap cost reverts V4TooMuchRequested.
    // -------------------------------------------------------------------------

    function testFuzz_increasePosition_maxDebtIn_revertsWhenTooLow(uint128 collateralToBuy, uint128 maxDebtIn) public {
        collateralToBuy = uint128(bound(collateralToBuy, 0.01 ether, DEEP_MAX_BUY));
        // At ~1:1 + 0.3% fee the swap costs more than collateralToBuy.  Cap maxDebtIn strictly
        // below collateralToBuy so it is certain to be less than the true cost.  Keep >= 1 to
        // avoid the SlippageBoundRequired guard.
        maxDebtIn = uint128(bound(maxDebtIn, 1, collateralToBuy - 1));

        address account = marginRouter.accountOf(address(this), 0);
        MockERC20(Currency.unwrap(collateral)).transfer(account, 1 ether);

        vm.expectPartialRevert(IV4Router.V4TooMuchRequested.selector);
        marginRouter.increasePosition(
            IMarginRouter.IncreaseParams({
                adapter: adapter,
                market: market,
                poolKey: deepPoolKey,
                equity: 0,
                collateralToBuy: collateralToBuy,
                maxDebtIn: maxDebtIn,
                minHopPriceX36: 0,
                maxLtvAfter: Ltv.wrap(0),
                subId: 0,
                deadline: block.timestamp + 1
            })
        );
    }

    // -------------------------------------------------------------------------
    // Property 4b: maxDebtIn >= DEEP_MAX_DEBT always succeeds on the deep pool.
    // -------------------------------------------------------------------------

    function testFuzz_increasePosition_maxDebtIn_succeedsWhenSufficient(uint128 collateralToBuy, uint128 maxDebtIn)
        public
    {
        collateralToBuy = uint128(bound(collateralToBuy, 1, DEEP_MAX_BUY));
        // DEEP_MAX_DEBT (12 ether) covers the worst-case cost of a DEEP_MAX_BUY (10 ether) swap.
        maxDebtIn = uint128(bound(maxDebtIn, DEEP_MAX_DEBT, type(uint128).max));

        address account = marginRouter.accountOf(address(this), 0);
        MockERC20(Currency.unwrap(collateral)).transfer(account, 1 ether);

        marginRouter.increasePosition(
            IMarginRouter.IncreaseParams({
                adapter: adapter,
                market: market,
                poolKey: deepPoolKey,
                equity: 0,
                collateralToBuy: collateralToBuy,
                maxDebtIn: maxDebtIn,
                minHopPriceX36: 0,
                maxLtvAfter: Ltv.wrap(0),
                subId: 0,
                deadline: block.timestamp + 1
            })
        );

        assertEq(
            protocol.collateralOf(account), 1 ether + uint256(collateralToBuy), "collateral = equity + collateralToBuy"
        );
        assertEq(IERC20(Currency.unwrap(collateral)).balanceOf(address(marginRouter)), 0, "router: no loose collateral");
        assertEq(IERC20(Currency.unwrap(debt)).balanceOf(address(marginRouter)), 0, "router: no loose debt");
    }

    // -------------------------------------------------------------------------
    // Property 5: No dust after open+close round-trip on the deep pool.
    //
    // After a full close, all lending positions are zero and neither the account nor the router
    // holds any loose collateral or debt tokens.
    // -------------------------------------------------------------------------

    function testFuzz_openClose_deepPool_noResidual(uint128 collateralToBuy) public {
        collateralToBuy = uint128(bound(collateralToBuy, 0.01 ether, DEEP_MAX_BUY));

        address account = marginRouter.accountOf(address(this), 0);
        MockERC20(Currency.unwrap(collateral)).transfer(account, 1 ether);

        marginRouter.increasePosition(
            IMarginRouter.IncreaseParams({
                adapter: adapter,
                market: market,
                poolKey: deepPoolKey,
                equity: 0,
                collateralToBuy: collateralToBuy,
                maxDebtIn: DEEP_MAX_DEBT,
                minHopPriceX36: 0,
                maxLtvAfter: Ltv.wrap(0),
                subId: 0,
                deadline: block.timestamp + 1
            })
        );

        marginRouter.decreasePosition(
            IMarginRouter.DecreaseParams({
                debtToRepay: type(uint256).max,
                maxLtvAfter: Ltv.wrap(0),
                adapter: adapter,
                market: market,
                poolKey: deepPoolKey,
                maxCollateralIn: DEEP_MAX_DEBT,
                minHopPriceX36: 0,
                subId: 0,
                deadline: block.timestamp + 1
            })
        );

        assertEq(protocol.debtOf(account), 0, "debt fully repaid");
        assertEq(protocol.collateralOf(account), 0, "collateral fully withdrawn");
        assertEq(IERC20(Currency.unwrap(collateral)).balanceOf(account), 0, "account: no loose collateral post-close");
        assertEq(IERC20(Currency.unwrap(debt)).balanceOf(account), 0, "account: no loose debt post-close");
        assertEq(
            IERC20(Currency.unwrap(collateral)).balanceOf(address(marginRouter)),
            0,
            "router: no loose collateral post-close"
        );
        assertEq(IERC20(Currency.unwrap(debt)).balanceOf(address(marginRouter)), 0, "router: no loose debt post-close");
    }

    // -------------------------------------------------------------------------
    // Property 5b: No dust after open+decrease on the deep pool.
    // -------------------------------------------------------------------------

    function testFuzz_openDecrease_deepPool_noResidual(uint128 collateralToBuy, uint128 debtToRepay) public {
        collateralToBuy = uint128(bound(collateralToBuy, 1 ether, DEEP_MAX_BUY));

        address account = marginRouter.accountOf(address(this), 0);
        MockERC20(Currency.unwrap(collateral)).transfer(account, 1 ether);

        marginRouter.increasePosition(
            IMarginRouter.IncreaseParams({
                adapter: adapter,
                market: market,
                poolKey: deepPoolKey,
                equity: 0,
                collateralToBuy: collateralToBuy,
                maxDebtIn: DEEP_MAX_DEBT,
                minHopPriceX36: 0,
                maxLtvAfter: Ltv.wrap(0),
                subId: 0,
                deadline: block.timestamp + 1
            })
        );

        uint256 totalDebt = protocol.debtOf(account);
        // Need at least 2 debt units so we can repay one and still keep the position open.
        if (totalDebt < 2) return;
        debtToRepay = uint128(bound(debtToRepay, 1, totalDebt - 1));

        marginRouter.decreasePosition(
            IMarginRouter.DecreaseParams({
                adapter: adapter,
                market: market,
                poolKey: deepPoolKey,
                debtToRepay: debtToRepay,
                maxCollateralIn: DEEP_MAX_DEBT,
                minHopPriceX36: 0,
                maxLtvAfter: toLtv(0.99e18),
                subId: 0,
                deadline: block.timestamp + 1
            })
        );

        assertLt(protocol.debtOf(account), totalDebt, "debt reduced");
        assertGt(protocol.debtOf(account), 0, "position still open");
        assertEq(IERC20(Currency.unwrap(collateral)).balanceOf(account), 0, "account: no loose collateral");
        assertEq(IERC20(Currency.unwrap(debt)).balanceOf(account), 0, "account: no loose debt");
        assertEq(IERC20(Currency.unwrap(collateral)).balanceOf(address(marginRouter)), 0, "router: no loose collateral");
        assertEq(IERC20(Currency.unwrap(debt)).balanceOf(address(marginRouter)), 0, "router: no loose debt");
    }

    // -------------------------------------------------------------------------
    // Property 6: close reverts atomically on a thin pool that cannot buy all debt.
    //
    // A position whose debt exceeds the thin band capacity cannot be closed through that pool: the
    // swap partial-fills, leaving an unsettled debt, and the unlock reverts.  No partial close.
    // -------------------------------------------------------------------------

    function testFuzz_close_thinPool_revertsOnPartialFill(uint128 collateralSeed, uint128 debtSeed) public {
        // Debt must exceed the thin band capacity so the buy is guaranteed to partial-fill.
        // THIN_MIN_OVERFLOW_BUY (1.1 ether) is above the band capacity confirmed by the regression.
        collateralSeed = uint128(bound(collateralSeed, THIN_MIN_OVERFLOW_BUY, 5 ether));
        debtSeed = uint128(bound(debtSeed, THIN_MIN_OVERFLOW_BUY, 5 ether));

        // Use subId 99 to avoid interfering with other tests.
        address account = marginRouter.createAccount(address(this), 99);

        // Seed the position directly, bypassing the open flow (which would fail on the thin pool).
        MockERC20(Currency.unwrap(collateral)).transfer(account, collateralSeed);
        MarginAccount(account).supplyCollateral(adapter, market, collateralSeed);
        MarginAccount(account).borrow(adapter, market, debtSeed, address(this));

        vm.expectRevert();
        marginRouter.decreasePosition(
            IMarginRouter.DecreaseParams({
                debtToRepay: type(uint256).max,
                maxLtvAfter: Ltv.wrap(0),
                adapter: adapter,
                market: market,
                poolKey: thinClosePoolKey,
                maxCollateralIn: type(uint128).max,
                minHopPriceX36: 0,
                subId: 99,
                deadline: block.timestamp + 1
            })
        );
    }

    // -------------------------------------------------------------------------
    // Property 7: a second increasePosition into the same account adds leverage (Fix C applies).
    //
    // The second open must also pass ASSERT_FILL, so the collateral position grows by exactly
    // the second collateralToBuy and the router remains clean.
    // -------------------------------------------------------------------------

    function testFuzz_increasePosition_secondOpen_deepPool_exactFill(uint128 firstBuy, uint128 secondBuy) public {
        firstBuy = uint128(bound(firstBuy, 1, DEEP_MAX_BUY / 2));
        secondBuy = uint128(bound(secondBuy, 1, DEEP_MAX_BUY / 2));

        address account = marginRouter.accountOf(address(this), 0);
        MockERC20(Currency.unwrap(collateral)).transfer(account, 1 ether);

        marginRouter.increasePosition(
            IMarginRouter.IncreaseParams({
                adapter: adapter,
                market: market,
                poolKey: deepPoolKey,
                equity: 0,
                collateralToBuy: firstBuy,
                maxDebtIn: DEEP_MAX_DEBT,
                minHopPriceX36: 0,
                maxLtvAfter: Ltv.wrap(0),
                subId: 0,
                deadline: block.timestamp + 1
            })
        );

        uint256 collateralAfterOpen = protocol.collateralOf(account);

        marginRouter.increasePosition(
            IMarginRouter.IncreaseParams({
                adapter: adapter,
                market: market,
                poolKey: deepPoolKey,
                equity: 0,
                collateralToBuy: secondBuy,
                maxDebtIn: DEEP_MAX_DEBT,
                minHopPriceX36: 0,
                maxLtvAfter: Ltv.wrap(0),
                subId: 0,
                deadline: block.timestamp + 1
            })
        );

        assertEq(
            protocol.collateralOf(account),
            collateralAfterOpen + uint256(secondBuy),
            "increase adds exactly secondBuy to collateral"
        );
        assertEq(IERC20(Currency.unwrap(collateral)).balanceOf(address(marginRouter)), 0, "router: no loose collateral");
        assertEq(IERC20(Currency.unwrap(debt)).balanceOf(address(marginRouter)), 0, "router: no loose debt");
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /// @dev Creates a v4 pool with liquidity in a single tick-spacing band [lowerTick, upperTick].
    ///      At SQRT_PRICE_1_1 (tick 0), a band of [0, 60] is immediately above the current price
    ///      and is exhausted quickly when buying collateral (selling debt).  The symmetric band
    ///      [-60, 0] is exhausted when selling collateral (buying debt) for the close direction.
    function _createThinPool(uint24 fee, int24 lowerTick, int24 upperTick) internal returns (PoolKey memory key) {
        key = PoolKey({currency0: collateral, currency1: debt, fee: fee, tickSpacing: 60, hooks: IHooks(address(0))});
        manager.initialize(key, SQRT_PRICE_1_1);
        MockERC20(Currency.unwrap(collateral)).approve(address(positionManager), type(uint256).max);
        MockERC20(Currency.unwrap(debt)).approve(address(positionManager), type(uint256).max);
        positionManager.modifyLiquidity(key, ModifyLiquidityParams(lowerTick, upperTick, 200 ether, 0), "0x");
    }
}
