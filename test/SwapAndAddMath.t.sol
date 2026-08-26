// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {LiquidityAmounts} from "../src/libraries/LiquidityAmounts.sol";
import {SwapAndAddMath} from "../src/libraries/SwapAndAddMath.sol";

/// @notice Focused tests for the pure SwapAndAddMath library. Everything here runs against the library
///         directly — no pool, no fixture — so the domains are the full sqrt-price space rather than what a
///         test pool can reach. Behavioral proofs that need a live pool (fee-aware dust tightness, extreme-tick
///         deployment) stay in SwapAndAddMathFuzz.t.sol; end-to-end trim behavior stays in SwapAndAddTrim.t.sol.
contract SwapAndAddMathTest is Test {
    uint256 constant PIPS = 1e6;

    // ─────────────────────────── getAmountsForLiquidity: round-up amounts ───────────────────────────

    /// @dev Branch selection: below range is token0-only, above is token1-only, in-range is both,
    ///      and unsorted bounds are normalized.
    function test_getAmountsForLiquidity_branches() public pure {
        uint160 sl = TickMath.getSqrtPriceAtTick(-600);
        uint160 su = TickMath.getSqrtPriceAtTick(600);
        uint128 liq = 1e18;

        (uint256 a0, uint256 a1) = SwapAndAddMath.getAmountsForLiquidity(sl - 1, sl, su, liq);
        assertGt(a0, 0, "below range: token0 only");
        assertEq(a1, 0, "below range: no token1");

        (a0, a1) = SwapAndAddMath.getAmountsForLiquidity(su, sl, su, liq);
        assertEq(a0, 0, "above range: no token0");
        assertGt(a1, 0, "above range: token1 only");

        (a0, a1) = SwapAndAddMath.getAmountsForLiquidity(TickMath.getSqrtPriceAtTick(0), sl, su, liq);
        assertGt(a0, 0, "in range: token0");
        assertGt(a1, 0, "in range: token1");

        (uint256 a0s, uint256 a1s) = SwapAndAddMath.getAmountsForLiquidity(TickMath.getSqrtPriceAtTick(0), su, sl, liq);
        assertEq(a0s, a0, "unsorted bounds normalized (amount0)");
        assertEq(a1s, a1, "unsorted bounds normalized (amount1)");
    }

    /// @dev The round-up amounts sit within one wei above an independent round-down oracle across the full
    ///      domain — catches branch-boundary mistakes (<= vs <) as well as rounding-direction slips. The
    ///      oracle is clamp-formulated (token0 spans [max(sp,sa), sb], token1 spans [sa, min(sp,sb)]) rather
    ///      than an if/else chain, so it does not mirror the implementation's structure.
    function testFuzz_getAmountsForLiquidity_withinOneWeiAboveRoundDown(
        uint160 spSeed,
        uint160 aSeed,
        uint160 bSeed,
        uint128 liq
    ) public pure {
        uint160 sp = uint160(bound(spSeed, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));
        uint160 sa = uint160(bound(aSeed, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        uint160 sb = uint160(bound(bSeed, uint256(sa) + 1, TickMath.MAX_SQRT_PRICE));

        (uint256 up0, uint256 up1) = SwapAndAddMath.getAmountsForLiquidity(sp, sa, sb, liq);
        uint160 lo0 = sp > sa ? sp : sa;
        uint256 down0 = lo0 < sb ? SqrtPriceMath.getAmount0Delta(lo0, sb, liq, false) : 0;
        uint160 hi1 = sp < sb ? sp : sb;
        uint256 down1 = hi1 > sa ? SqrtPriceMath.getAmount1Delta(sa, hi1, liq, false) : 0;

        assertGe(up0, down0, "round-up amount0 below round-down");
        assertLe(up0, down0 + 1, "amount0 rounding differs by more than one wei");
        assertGe(up1, down1, "round-up amount1 below round-down");
        assertLe(up1, down1 + 1, "amount1 rounding differs by more than one wei");
    }

    // ──────────────────── getLiquidityForAmountsWeighted: value-weighted sizing ────────────────────

    /// @dev Single-sided token1 budget with the range fully below spot: the weighted sizing must agree with
    ///      v4's direct getLiquidityForAmount1 (the value detour through the numeraire cancels out).
    function testFuzz_weighted_singleSidedToken1_matchesDirectFormula(
        int24 tlSeed,
        int24 widthSeed,
        uint160 spSeed,
        uint256 b1Seed
    ) public pure {
        int24 tl = int24(bound(tlSeed, -340_000, 339_000));
        int24 width = int24(bound(widthSeed, 10, 1000));
        uint160 sl = TickMath.getSqrtPriceAtTick(tl);
        uint160 su = TickMath.getSqrtPriceAtTick(tl + width);
        uint160 sp = uint160(bound(spSeed, su, TickMath.MAX_SQRT_PRICE));
        uint256 b1 = bound(b1Seed, 1e9, 1e27);

        uint256 rawFeasible = FullMath.mulDiv(b1, FixedPoint96.Q96, su - sl);
        vm.assume(rawFeasible >= 1e6 && rawFeasible < type(uint128).max);
        uint128 feasible = LiquidityAmounts.getLiquidityForAmount1(sl, su, b1);

        // the numeraire conversion rounds down on both the reference and the budget, so the deviation from
        // the direct formula is a few wei in either direction, relative-bounded by the reference's magnitude
        uint128 sized = SwapAndAddMath.getLiquidityForAmountsWeighted(sp, sl, su, 0, b1, PIPS, PIPS);
        assertApproxEqAbs(sized, feasible, feasible / 1e6 + 2, "weighted deviates from direct single-sided token1");
    }

    /// @dev Single-sided token0 mirror: range fully above spot vs v4's direct getLiquidityForAmount0.
    function testFuzz_weighted_singleSidedToken0_matchesDirectFormula(
        int24 tlSeed,
        int24 widthSeed,
        uint160 spSeed,
        uint256 b0Seed
    ) public pure {
        int24 tl = int24(bound(tlSeed, -340_000, 339_000));
        int24 width = int24(bound(widthSeed, 10, 1000));
        uint160 sl = TickMath.getSqrtPriceAtTick(tl);
        uint160 su = TickMath.getSqrtPriceAtTick(tl + width);
        uint160 sp = uint160(bound(spSeed, TickMath.MIN_SQRT_PRICE, sl));
        uint256 b0 = bound(b0Seed, 1e9, 1e27);

        uint256 intermediate = FullMath.mulDiv(sl, su, FixedPoint96.Q96);
        uint256 rawFeasible = FullMath.mulDiv(b0, intermediate, su - sl);
        vm.assume(rawFeasible >= 1e6 && rawFeasible < type(uint128).max);
        uint128 feasible = LiquidityAmounts.getLiquidityForAmount0(sl, su, b0);

        uint128 sized = SwapAndAddMath.getLiquidityForAmountsWeighted(sp, sl, su, b0, 0, PIPS, PIPS);
        assertApproxEqAbs(sized, feasible, feasible / 1e6 + 2, "weighted deviates from direct single-sided token0");
    }

    /// @dev In-range mediant property: the value-weighted size lies between the two single-token feasibility
    ///      ratios (b0-only over [sp,su] and b1-only over [sl,sp]). Fails if either side's valuation is
    ///      mis-weighted — the pure-level counterpart of the behavioral dust fuzz.
    function testFuzz_weighted_inRange_liesBetweenSingleTokenRatios(
        int24 tickSeed,
        int24 widthSeed,
        uint256 b0Seed,
        uint256 b1Seed
    ) public pure {
        int24 tick = int24(bound(tickSeed, -200_000, 200_000));
        int24 width = int24(bound(widthSeed, 60, 100_000));
        uint160 sp = TickMath.getSqrtPriceAtTick(tick);
        uint160 sl = TickMath.getSqrtPriceAtTick(tick - width);
        uint160 su = TickMath.getSqrtPriceAtTick(tick + width);
        uint256 b0 = bound(b0Seed, 0, 1e24);
        uint256 b1 = bound(b1Seed, 0, 1e24);
        vm.assume(b0 + b1 >= 1e12);

        uint256 rawL0 = FullMath.mulDiv(b0, FullMath.mulDiv(sp, su, FixedPoint96.Q96), su - sp);
        uint256 rawL1 = FullMath.mulDiv(b1, FixedPoint96.Q96, sp - sl);
        vm.assume(rawL0 < type(uint128).max && rawL1 < type(uint128).max);
        uint256 minL = rawL0 < rawL1 ? rawL0 : rawL1;
        uint256 maxL = rawL0 < rawL1 ? rawL1 : rawL0;
        vm.assume(maxL >= 1e6);

        uint256 sized = SwapAndAddMath.getLiquidityForAmountsWeighted(sp, sl, su, b0, b1, PIPS, PIPS);
        assertLe(sized, maxL + maxL / 1e6 + 2, "weighted above the larger single-token ratio");
        assertGe(sized + minL / 1e6 + 2, minL, "weighted below the smaller single-token ratio");
    }

    /// @dev Growing either budget never shrinks the sized liquidity.
    function testFuzz_weighted_monotonicInBudgets(
        int24 tickSeed,
        int24 widthSeed,
        uint256 b0Seed,
        uint256 b1Seed,
        uint256 extraSeed,
        bool growToken0
    ) public pure {
        int24 tick = int24(bound(tickSeed, -200_000, 200_000));
        int24 width = int24(bound(widthSeed, 60, 100_000));
        uint160 sp = TickMath.getSqrtPriceAtTick(tick);
        uint160 sl = TickMath.getSqrtPriceAtTick(tick - width);
        uint160 su = TickMath.getSqrtPriceAtTick(tick + width);
        uint256 b0 = bound(b0Seed, 0, 1e24);
        uint256 b1 = bound(b1Seed, 0, 1e24);
        uint256 extra = bound(extraSeed, 1, 1e24);

        uint128 base = SwapAndAddMath.getLiquidityForAmountsWeighted(sp, sl, su, b0, b1, PIPS, PIPS);
        uint128 grown = growToken0
            ? SwapAndAddMath.getLiquidityForAmountsWeighted(sp, sl, su, b0 + extra, b1, PIPS, PIPS)
            : SwapAndAddMath.getLiquidityForAmountsWeighted(sp, sl, su, b0, b1 + extra, PIPS, PIPS);
        assertGe(grown, base, "more budget sized less liquidity");
    }

    function test_weighted_zeroBudgets_returnsZero() public pure {
        uint160 sp = TickMath.getSqrtPriceAtTick(0);
        uint160 sl = TickMath.getSqrtPriceAtTick(-600);
        uint160 su = TickMath.getSqrtPriceAtTick(600);
        assertEq(SwapAndAddMath.getLiquidityForAmountsWeighted(sp, sl, su, 0, 0, PIPS, PIPS), 0);
    }

    // ─────────────────────────── getLiquidityFeeAware: directional discount ───────────────────────────

    /// @dev With zero fees the fee-aware entry collapses to the plain weighted sizing exactly.
    function testFuzz_feeAware_zeroFee_equalsWeighted(int24 tickSeed, int24 widthSeed, uint256 b0Seed, uint256 b1Seed)
        public
        pure
    {
        int24 tick = int24(bound(tickSeed, -200_000, 200_000));
        int24 width = int24(bound(widthSeed, 60, 100_000));
        uint160 sp = TickMath.getSqrtPriceAtTick(tick);
        uint160 sl = TickMath.getSqrtPriceAtTick(tick - width);
        uint160 su = TickMath.getSqrtPriceAtTick(tick + width);
        uint256 b0 = bound(b0Seed, 0, 1e24);
        uint256 b1 = bound(b1Seed, 0, 1e24);

        assertEq(
            SwapAndAddMath.getLiquidityFeeAware(sp, sl, su, b0, b1, 0, 0),
            SwapAndAddMath.getLiquidityForAmountsWeighted(sp, sl, su, b0, b1, PIPS, PIPS),
            "zero-fee sizing deviates from weighted"
        );
    }

    /// @dev The discount only ever shrinks the size: discounting the surplus side lowers the budget's value
    ///      by a larger fraction than the reference's (the budget is surplus-heavy by definition). Fails if
    ///      the discount lands on the deficit side instead — a percent-scale error, far above the wei-scale
    ///      rounding tolerance. Budgets are kept above dust so value-conversion rounding cannot dominate.
    function testFuzz_feeAware_neverExceedsUndiscounted(
        int24 tickSeed,
        int24 widthSeed,
        uint256 b0Seed,
        uint256 b1Seed,
        uint16 pf01Seed,
        uint16 pf10Seed,
        uint24 lpFeeSeed
    ) public pure {
        int24 tick = int24(bound(tickSeed, -200_000, 200_000));
        int24 width = int24(bound(widthSeed, 60, 100_000));
        uint160 sp = TickMath.getSqrtPriceAtTick(tick);
        uint160 sl = TickMath.getSqrtPriceAtTick(tick - width);
        uint160 su = TickMath.getSqrtPriceAtTick(tick + width);
        uint256 b0 = bound(b0Seed, 0, 1e24);
        uint256 b1 = bound(b1Seed, 0, 1e24);
        vm.assume(b0 + b1 >= 1e12);
        uint24 protocolFee = uint24(bound(pf01Seed, 0, 1000)) | (uint24(bound(pf10Seed, 0, 1000)) << 12);
        uint24 lpFee = uint24(bound(lpFeeSeed, 0, 100_000)); // up to 10%, the realistic LP fee ceiling

        uint256 feeAware = SwapAndAddMath.getLiquidityFeeAware(sp, sl, su, b0, b1, protocolFee, lpFee);
        uint256 mid = SwapAndAddMath.getLiquidityForAmountsWeighted(sp, sl, su, b0, b1, PIPS, PIPS);
        assertLe(feeAware, mid + mid / 1e9 + 2, "fee discount increased the sized liquidity");
    }

    /// @dev The discount uses the swap fee of the direction the reconcile will actually trade: token0 surplus
    ///      sells token0 (zeroForOne fee), token1 surplus sells token1 (oneForZero fee).
    function test_feeAware_usesDirectionalProtocolFee() public pure {
        uint160 sp = TickMath.getSqrtPriceAtTick(0);
        uint160 sl = TickMath.getSqrtPriceAtTick(-600);
        uint160 su = TickMath.getSqrtPriceAtTick(600);
        uint24 lpFee = 3000;
        // Asymmetric protocol fee: 900 pips zeroForOne, 100 pips oneForZero.
        uint24 protocolFee = 900 | (uint24(100) << 12);

        // Token0 surplus (b1 = 0): must discount by the zeroForOne swap fee.
        uint256 fee01 = ProtocolFeeLibrary.calculateSwapFee(uint16(900), lpFee);
        assertEq(
            SwapAndAddMath.getLiquidityFeeAware(sp, sl, su, 2e18, 0, protocolFee, lpFee),
            SwapAndAddMath.getLiquidityForAmountsWeighted(sp, sl, su, 2e18, 0, PIPS - fee01, PIPS),
            "token0 surplus not discounted by the zeroForOne fee"
        );

        // Token1 surplus (b0 = 0): must discount by the oneForZero swap fee.
        uint256 fee10 = ProtocolFeeLibrary.calculateSwapFee(uint16(100), lpFee);
        assertEq(
            SwapAndAddMath.getLiquidityFeeAware(sp, sl, su, 0, 2e18, protocolFee, lpFee),
            SwapAndAddMath.getLiquidityForAmountsWeighted(sp, sl, su, 0, 2e18, PIPS, PIPS - fee10),
            "token1 surplus not discounted by the oneForZero fee"
        );
    }

    // ──────────────────────────── getLiquidityToFree: the trim inverse ────────────────────────────

    /// @dev what v4 actually frees for `dl` (round DOWN, the pool's favour)
    function freed0(uint160 lo, uint160 su, uint128 dl) internal pure returns (uint256) {
        return SqrtPriceMath.getAmount0Delta(lo, su, dl, false);
    }

    function freed1(uint160 sl, uint160 hi, uint128 dl) internal pure returns (uint256) {
        return SqrtPriceMath.getAmount1Delta(sl, hi, dl, false);
    }

    /// @dev Full-domain fuzz: burning the round-up `dl` must free >= amountOut under v4's round-DOWN burn.
    ///      Passing sp == sl makes the price clamp pass-through so [lo, su] is fuzzed directly.
    function testFuzz_toFree_token0_neverUnderFrees(uint160 loSeed, uint160 suSeed, uint256 amountSeed) public pure {
        uint160 lo = uint160(bound(loSeed, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        uint160 su = uint160(bound(suSeed, uint256(lo) + 1, TickMath.MAX_SQRT_PRICE));
        // the debt is CORRELATED with the geometry in-contract: it can never exceed what a max-liquidity
        // position holds in token0 over [lo, su]. (Uncorrelated hugeness makes the inverse's mulDiv overflow
        // and revert — reachable only in an astronomically boundary-pinned state; see the library note.)
        uint256 maxDebt = SqrtPriceMath.getAmount0Delta(lo, su, type(uint128).max, false);
        if (maxDebt == 0) return; // no token0 exists in this sliver of geometry — nothing to invert
        uint256 amountOut = bound(amountSeed, 1, maxDebt);

        uint256 dlUp = SwapAndAddMath.getLiquidityToFree(lo, lo, su, false, amountOut);
        // the cap path (dlUp >= lopt) is the dust regime, pinned separately; here pin the inverse
        if (dlUp > type(uint128).max) return;

        assertGe(freed0(lo, su, uint128(dlUp)), amountOut, "round-up inverse must never under-free token0");
    }

    /// @dev Token1 mirror; sp == su makes the clamp pass-through so [sl, hi] is fuzzed directly.
    function testFuzz_toFree_token1_neverUnderFrees(uint160 slSeed, uint160 hiSeed, uint128 amountSeed) public pure {
        uint160 sl = uint160(bound(slSeed, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        uint160 hi = uint160(bound(hiSeed, uint256(sl) + 1, TickMath.MAX_SQRT_PRICE));
        uint128 amountOut = uint128(bound(amountSeed, 1, type(uint128).max));

        uint256 dlUp = SwapAndAddMath.getLiquidityToFree(hi, sl, hi, true, amountOut);
        if (dlUp > type(uint128).max) return;

        assertGe(freed1(sl, hi, uint128(dlUp)), amountOut, "round-up inverse must never under-free token1");
    }

    /// @dev A price outside the range clamps to the boundary: below the range the token0 side spans the full
    ///      range; above it the token1 side does.
    function test_toFree_priceClampsToRangeBoundary() public pure {
        uint160 sl = TickMath.getSqrtPriceAtTick(-600);
        uint160 su = TickMath.getSqrtPriceAtTick(600);

        assertEq(
            SwapAndAddMath.getLiquidityToFree(sl - 1000, sl, su, false, 1e18),
            SwapAndAddMath.getLiquidityToFree(sl, sl, su, false, 1e18),
            "token0: price below range must clamp to sqrtLower"
        );
        assertEq(
            SwapAndAddMath.getLiquidityToFree(su + 1000, sl, su, true, 1e18),
            SwapAndAddMath.getLiquidityToFree(su, sl, su, true, 1e18),
            "token1: price above range must clamp to sqrtUpper"
        );
    }

    /// @dev the PREVIOUS (broken) token0 trim: floor conversion, then +1 liquidity unit. Kept as the
    ///      historical counter-spec the shipped inverse replaced.
    function oldDl0(uint160 lo, uint160 su, uint256 amountOut, uint128 lopt) internal pure returns (uint128 dl) {
        dl = LiquidityAmounts.getLiquidityForAmount0(lo, su, amountOut);
        dl = dl >= lopt ? lopt : dl + 1;
    }

    /// @dev Why the old formula broke at scale: exact replay of a reverting-add trace (post-swap price
    ///      tick 4, range upper tick 60, ~4.5e26 residual token0 debt). "+1 unit of LIQUIDITY" is not
    ///      "+1 wei of TOKEN": one liquidity unit is worth `2^96*(su-lo)/(su*lo)` wei of token0, far below
    ///      one wei for narrow ranges, while the floored conversion's error SCALES with the amount.
    function test_toFree_oldFormula_freesOneWeiTooLittleAtScale() public pure {
        uint160 lo = 79244399350305758162296141626;
        uint160 su = TickMath.getSqrtPriceAtTick(60);
        uint256 amountOut = 450747982730666145637418463;
        uint128 lopt = 734433823997602534344379205275051; // the just-minted liquidity (not binding here)

        uint128 dl = oldDl0(lo, su, amountOut, lopt);
        assertLt(dl, lopt, "the lopt cap is NOT what bites here");
        uint256 got = freed0(lo, su, dl);
        assertEq(amountOut - got, 1, "the old trim frees EXACTLY one wei less than the debt");

        // one unit of liquidity is worth far less than one wei of token0 here -> "+1" was a no-op economically
        assertEq(freed0(lo, su, 1), 0, "1 unit of liquidity frees 0 wei of token0 in this range");

        // the shipped inverse covers it
        uint256 dlNew = SwapAndAddMath.getLiquidityToFree(lo, lo, su, false, amountOut);
        assertLe(dlNew, type(uint128).max);
        assertGe(freed0(lo, su, uint128(dlNew)), amountOut, "shipped inverse covers the debt");
    }

    /// @dev The dust regime is NOT a formula error: the pool's own mint-up/burn-down rounding keeps the wei,
    ///      so no inverse — however exact — can free it. (This is what a non-zero minLiquidity floor surfaces
    ///      as InsufficientLiquidity; see SwapAndAddTrim.t.sol.)
    function test_toFree_dustRegime_mintRoundsUpBurnRoundsDownToZero() public pure {
        uint160 sp = TickMath.getSqrtPriceAtTick(0);
        uint160 sl = TickMath.getSqrtPriceAtTick(-10);
        uint128 lopt = 997;

        // the mint pulls 1 wei of token1 (rounded up); burning the SAME liquidity returns 0 (rounded down)
        assertEq(SqrtPriceMath.getAmount1Delta(sl, sp, lopt, true), 1, "MINT requires 1 wei of token1");
        assertEq(SqrtPriceMath.getAmount1Delta(sl, sp, lopt, false), 0, "BURN returns 0 wei of token1");

        // even the exact round-up inverse asks for more liquidity than exists -> the lopt cap must bite
        assertGt(SwapAndAddMath.getLiquidityToFree(sp, sl, sp, true, 1), lopt, "toll wei needs more than was added");

        // the same asymmetry on token0: 259 in, 258 out
        assertEq(SqrtPriceMath.getAmount0Delta(sp, TickMath.getSqrtPriceAtTick(6000), lopt, true), 259);
        assertEq(SqrtPriceMath.getAmount0Delta(sp, TickMath.getSqrtPriceAtTick(6000), lopt, false), 258);
    }

    /// @dev The shipped inverse never under-frees: widths x amounts x price levels, including the low-price
    ///      levels where the old formula's error exploded and non-boundary prices where the intermediate
    ///      truncates. (Price level tick 0 is the blind spot; kept for coverage.)
    function test_toFree_shippedInverse_neverUnderFrees() public pure {
        int24[5] memory bases = [int24(0), int24(-100_000), int24(-207_240), int24(-400_000), int24(200_000)];
        int24[5] memory widths = [int24(1), int24(2), int24(60), int24(600), int24(6000)];
        uint256[7] memory amounts = [uint256(1), 1e6, 1e12, 1e18, 1e24, 1e30, 1e33];

        for (uint256 b = 0; b < bases.length; b++) {
            for (uint256 w = 0; w < widths.length; w++) {
                uint160 lo = TickMath.getSqrtPriceAtTick(bases[b]);
                uint160 su = TickMath.getSqrtPriceAtTick(bases[b] + widths[w]);
                uint160 sl = TickMath.getSqrtPriceAtTick(bases[b] - widths[w]);
                // a non-boundary price inside the range: truncation is maximal off the exact tick prices
                uint160 mid = lo + uint160(uint256(keccak256(abi.encode(b, w))) % uint256(su - lo));
                if (mid <= lo) mid = lo + 1;

                for (uint256 i = 0; i < amounts.length; i++) {
                    uint256 a = amounts[i];
                    // token0 branch, from the boundary and from a mid-range price
                    _check0(lo, su, a);
                    _check0(mid, su, a);
                    // token1 branch
                    _check1(sl, lo, a);
                    _check1(sl, mid, a);
                }
            }
        }
    }

    function _check0(uint160 lo, uint160 su, uint256 a) internal pure {
        if (su <= lo) return;
        uint256 dl = SwapAndAddMath.getLiquidityToFree(lo, lo, su, false, a);
        if (dl > type(uint128).max) return; // would be capped at lopt in the contract
        assertGe(freed0(lo, su, uint128(dl)), a, "token0 inverse under-freed");
    }

    function _check1(uint160 sl, uint160 hi, uint256 a) internal pure {
        if (hi <= sl) return;
        uint256 dl = SwapAndAddMath.getLiquidityToFree(hi, sl, hi, true, a);
        if (dl > type(uint128).max) return;
        assertGe(freed1(sl, hi, uint128(dl)), a, "token1 inverse under-freed");
    }

    /// @dev Pin for the documented informational limit: with the price within sqrt-units of sqrtUpper and an
    ///      enormous token0 debt outstanding, the inverse's final mulDiv result exceeds uint256 and reverts —
    ///      self-inflicted, atomic, transient. Unreachable through the contract without a returns-delta hook.
    function test_toFree_revertsAtDocumentedFarEdge() public {
        uint160 su = TickMath.MAX_SQRT_PRICE;
        uint160 lo = su - 1;
        vm.expectRevert();
        this.callToFree(lo, lo, su, false, 1e33);
    }

    /// @dev external indirection so vm.expectRevert observes the library revert
    function callToFree(uint160 sp, uint160 sl, uint160 su, bool deficitIsCurrency1, uint256 amountToCover)
        external
        pure
        returns (uint256)
    {
        return SwapAndAddMath.getLiquidityToFree(sp, sl, su, deficitIsCurrency1, amountToCover);
    }
}
