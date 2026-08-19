// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {LiquidityAmounts} from "../src/libraries/LiquidityAmounts.sol";

/// @notice Pure-math regression for SwapAndAdd._trim's token->liquidity inverse.
///
///  _trim wants: DECREASE by `dl` liquidity so that the amount the DECREASE frees (which v4 rounds DOWN,
///  SqrtPriceMath.getAmount{0,1}Delta(..., roundUp=false)) is >= `amountOut`.
///
///  The first two tests document why the previous formula (floor-rounding LiquidityAmounts + "+1 liquidity
///  unit") was wrong: "+1 unit of LIQUIDITY" is not "+1 wei of TOKEN" — one liquidity unit is worth
///  `2^96*(su-lo)/(su*lo)` wei of token0, far below one wei for narrow/near-boundary ranges, while
///  getLiquidityForAmount0's floored intermediate has an error that SCALES with the amount. The last test
///  verifies the shipped round-up inverse never under-frees, across widths, amounts and price levels
///  including the low prices where the old formula broke (price 1 is the one level where the intermediate
///  does not truncate, so a price-1-only sweep proves nothing).
contract SwapAndAddTrimMathTest is Test {
    /// @dev the PREVIOUS (broken) token0 trim: floor conversion, then +1 liquidity unit
    function oldDl0(uint160 lo, uint160 su, uint256 amountOut, uint128 lopt) internal pure returns (uint128 dl) {
        dl = LiquidityAmounts.getLiquidityForAmount0(lo, su, amountOut);
        dl = dl >= lopt ? lopt : dl + 1;
    }

    /// @dev the PREVIOUS token1 trim
    function oldDl1(uint160 sl, uint160 hi, uint256 amountOut, uint128 lopt) internal pure returns (uint128 dl) {
        dl = LiquidityAmounts.getLiquidityForAmount1(sl, hi, amountOut);
        dl = dl >= lopt ? lopt : dl + 1;
    }

    /// @dev the SHIPPED token0 inverse, mirrored verbatim from _trim: round up every division, over amountOut+1
    function newDl0(uint160 lo, uint160 su, uint256 amountOut) internal pure returns (uint256) {
        uint256 intermediate = FullMath.mulDivRoundingUp(lo, su, FixedPoint96.Q96);
        return FullMath.mulDivRoundingUp(amountOut + 1, intermediate, su - lo);
    }

    /// @dev the SHIPPED token1 inverse
    function newDl1(uint160 sl, uint160 hi, uint256 amountOut) internal pure returns (uint256) {
        return FullMath.mulDivRoundingUp(amountOut + 1, FixedPoint96.Q96, hi - sl);
    }

    /// @dev what v4 actually frees for `dl` (round DOWN, the pool's favour)
    function freed0(uint160 lo, uint160 su, uint128 dl) internal pure returns (uint256) {
        return SqrtPriceMath.getAmount0Delta(lo, su, dl, false);
    }

    function freed1(uint160 sl, uint160 hi, uint128 dl) internal pure returns (uint256) {
        return SqrtPriceMath.getAmount1Delta(sl, hi, dl, false);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // 1. Why the old formula broke at scale: exact replay of a reverting-add trace (post-swap
    //    price tick 4, range upper tick 60, ~4.5e26 residual token0 debt)
    // ─────────────────────────────────────────────────────────────────────────────────────────

    function test_trimMath_oldFormula_freesOneWeiTooLittleAtScale() public pure {
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
        uint256 dlNew = newDl0(lo, su, amountOut);
        assertLe(dlNew, type(uint128).max);
        assertGe(freed0(lo, su, uint128(dlNew)), amountOut, "shipped inverse covers the debt");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // 2. The dust regime is NOT a formula error: the pool's own mint-up/burn-down rounding keeps
    //    the wei, so no inverse — however exact — can free it. (This is what the non-zero-minLiquidity
    //    floor surfaces as InsufficientLiquidity; see SwapAndAddTrim.t.sol.)
    // ─────────────────────────────────────────────────────────────────────────────────────────

    function test_trimMath_dustRegime_mintRoundsUpBurnRoundsDownToZero() public pure {
        uint160 sp = TickMath.getSqrtPriceAtTick(0);
        uint160 sl = TickMath.getSqrtPriceAtTick(-10);
        uint128 lopt = 997;

        // the mint pulls 1 wei of token1 (rounded up); burning the SAME liquidity returns 0 (rounded down)
        assertEq(SqrtPriceMath.getAmount1Delta(sl, sp, lopt, true), 1, "MINT requires 1 wei of token1");
        assertEq(SqrtPriceMath.getAmount1Delta(sl, sp, lopt, false), 0, "BURN returns 0 wei of token1");

        // even the exact round-up inverse asks for more liquidity than exists -> the lopt cap must bite
        assertGt(newDl1(sl, sp, 1), lopt, "the toll wei needs more liquidity than was added");

        // the same asymmetry on token0: 259 in, 258 out
        assertEq(SqrtPriceMath.getAmount0Delta(sp, TickMath.getSqrtPriceAtTick(6000), lopt, true), 259);
        assertEq(SqrtPriceMath.getAmount0Delta(sp, TickMath.getSqrtPriceAtTick(6000), lopt, false), 258);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // 3. The shipped inverse never under-frees: widths x amounts x price levels, including the
    //    low-price levels where the old formula's error exploded and non-boundary prices where
    //    the intermediate truncates. (Price level tick 0 is the blind spot; kept for coverage.)
    // ─────────────────────────────────────────────────────────────────────────────────────────

    function test_trimMath_shippedInverse_neverUnderFrees() public pure {
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
        uint256 dl = newDl0(lo, su, a);
        if (dl > type(uint128).max) return; // would be capped at lopt in the contract
        assertGe(freed0(lo, su, uint128(dl)), a, "token0 inverse under-freed");
    }

    function _check1(uint160 sl, uint160 hi, uint256 a) internal pure {
        if (hi <= sl) return;
        uint256 dl = newDl1(sl, hi, a);
        if (dl > type(uint128).max) return;
        assertGe(freed1(sl, hi, uint128(dl)), a, "token1 inverse under-freed");
    }
}
