// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";

/// @title SwapAndAddMath
/// @notice Pure sizing and trim math for SwapAndAdd. All functions are stateless: callers supply the live
///         sqrt price, range bounds, and fee configuration.
library SwapAndAddMath {
    using SafeCast for uint256;

    uint256 internal constant PIPS_DENOMINATOR = 1e6;
    /// @dev Sizing reference: maximal so the reference-scaling quantization is negligible.
    uint128 internal constant REFERENCE_LIQUIDITY = type(uint128).max;

    /// @notice Sizes liquidity accounting for directional swap fees on the surplus token.
    /// @dev First calculates a mid-price baseline size to find which token has a surplus, then discounts that
    ///      surplus token's value by the combined pool fee (LP fee + directional protocol fee).
    ///      Discounting the surplus side on both the budget and the reference position nets to charging the
    ///      fee on exactly the swapped amount.
    function getLiquidityFeeAware(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceLowerX96,
        uint160 sqrtPriceUpperX96,
        uint256 budget0,
        uint256 budget1,
        uint24 protocolFee,
        uint24 lpFee
    ) internal pure returns (uint128) {
        uint128 midLiquidity = getLiquidityForAmountsWeighted(
            sqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, budget0, budget1, PIPS_DENOMINATOR, PIPS_DENOMINATOR
        );
        (uint256 mid0, uint256 mid1) =
            getAmountsForLiquidity(sqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, midLiquidity);
        if (budget0 > mid0) {
            // Token0 surplus: reconcile swap sells token0 (zeroForOne), discount token0 value by fee.
            uint256 feePips =
                ProtocolFeeLibrary.calculateSwapFee(ProtocolFeeLibrary.getZeroForOneFee(protocolFee), lpFee);
            return getLiquidityForAmountsWeighted(
                sqrtPriceX96,
                sqrtPriceLowerX96,
                sqrtPriceUpperX96,
                budget0,
                budget1,
                PIPS_DENOMINATOR - feePips,
                PIPS_DENOMINATOR
            );
        } else if (budget1 > mid1) {
            // Token1 surplus: reconcile swap sells token1 (oneForZero), discount token1 value by fee.
            uint256 feePips =
                ProtocolFeeLibrary.calculateSwapFee(ProtocolFeeLibrary.getOneForZeroFee(protocolFee), lpFee);
            return getLiquidityForAmountsWeighted(
                sqrtPriceX96,
                sqrtPriceLowerX96,
                sqrtPriceUpperX96,
                budget0,
                budget1,
                PIPS_DENOMINATOR,
                PIPS_DENOMINATOR - feePips
            );
        }
        // Holdings are already in exact proportion; no fee discount needed.
        return midLiquidity;
    }

    /// @notice Computes liquidity by scaling reference liquidity against budget value in the cheaper token.
    /// @param pipsWeight0 Value weight applied to token0, in pips of PIPS_DENOMINATOR.
    /// @param pipsWeight1 Value weight applied to token1, in pips of PIPS_DENOMINATOR.
    function getLiquidityForAmountsWeighted(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceLowerX96,
        uint160 sqrtPriceUpperX96,
        uint256 amount0,
        uint256 amount1,
        uint256 pipsWeight0,
        uint256 pipsWeight1
    ) internal pure returns (uint128) {
        // Price >= 1 values both sides in token1 terms via rateX96 = sqrtPrice^2 / Q96 (token1 per token0);
        // price < 1 values in token0 terms via rateX96 = Q96^3 / sqrtPrice^2 (split to prevent intermediate
        // overflow). Valuing in the cheaper token keeps the rate multiplier >= Q96 across extreme ticks.
        bool isToken1Cheaper = sqrtPriceX96 >= FixedPoint96.Q96;
        uint256 rateX96 = isToken1Cheaper
            ? FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96)
            : FullMath.mulDiv(
                FullMath.mulDiv(FixedPoint96.Q96, FixedPoint96.Q96, sqrtPriceX96), FixedPoint96.Q96, sqrtPriceX96
            );

        uint256 refValue;
        {
            (uint256 ref0, uint256 ref1) =
                getAmountsForLiquidity(sqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, REFERENCE_LIQUIDITY);
            refValue = _weightedValue(ref0, ref1, rateX96, isToken1Cheaper, pipsWeight0, pipsWeight1);
        }
        if (refValue == 0) return 0;
        // Scale reference liquidity: L = REFERENCE_LIQUIDITY * budgetValue / refValue.
        // Truncating towards zero here is the safe direction (any leftover budget is swept as dust).
        uint256 budgetValue = _weightedValue(amount0, amount1, rateX96, isToken1Cheaper, pipsWeight0, pipsWeight1);
        return FullMath.mulDiv(REFERENCE_LIQUIDITY, budgetValue, refValue).toUint128();
    }

    /// @notice Calculates token amounts required for a given liquidity amount at current price/range.
    /// @dev Rounds UP to mirror POSM's MINT_POSITION — callers funding a mint from these amounts are never
    ///      a wei short of POSM's pull. NOT interchangeable with LiquidityAmounts (which rounds down).
    ///      The A/B bounds follow LiquidityAmounts' convention: they may be passed in either order.
    function getAmountsForLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }
        if (sqrtPriceX96 <= sqrtPriceAX96) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceAX96, sqrtPriceBX96, liquidity, true);
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtPriceBX96, liquidity, true);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtPriceAX96, sqrtPriceX96, liquidity, true);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtPriceAX96, sqrtPriceBX96, liquidity, true);
        }
    }

    /// @notice Computes the liquidity to burn so that v4's rounded-DOWN return covers `amountToCover` of the
    ///         deficit token.
    /// @dev Exact ceil inverse over `amountToCover + 1`: the nested-floor bound guarantees freed >= amountToCover.
    ///      Assumes the price is not past the range's far side for the deficit token (SwapAndAdd's reconcile
    ///      flow guarantees this); a price outside the near side clamps to the boundary.
    /// @return liquidityToFree The round-up liquidity to burn, uncapped — callers cap against the liquidity they added.
    function getLiquidityToFree(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceLowerX96,
        uint160 sqrtPriceUpperX96,
        bool deficitIsCurrency1,
        uint256 amountToCover
    ) internal pure returns (uint256 liquidityToFree) {
        if (deficitIsCurrency1) {
            // Token1 occupies [sqrtLower, min(price, sqrtUpper)]: amount1 = L * (hi - lo) / Q96.
            uint160 clampedUpper = sqrtPriceX96 < sqrtPriceUpperX96 ? sqrtPriceX96 : sqrtPriceUpperX96;
            liquidityToFree =
                FullMath.mulDivRoundingUp(amountToCover + 1, FixedPoint96.Q96, clampedUpper - sqrtPriceLowerX96);
        } else {
            // Token0 occupies [max(price, sqrtLower), sqrtUpper]: amount0 = L * Q96 * (hi - lo) / (hi * lo).
            uint160 clampedLower = sqrtPriceX96 > sqrtPriceLowerX96 ? sqrtPriceX96 : sqrtPriceLowerX96;
            // Informational: Below tick ~-665k (lo * hi < Q96), rounding up this sub-1 quotient over-trims by
            // a factor of up to ~2^32, which the caller's cap safely absorbs without fund loss.
            uint256 intermediate = FullMath.mulDivRoundingUp(clampedLower, sqrtPriceUpperX96, FixedPoint96.Q96);
            // Informational: At extreme prices where post-swap price is within sqrt-units of sqrtUpper with large
            // deficit remaining, this intermediate quotient can overflow uint256 and revert (self-inflicted, safe).
            liquidityToFree =
                FullMath.mulDivRoundingUp(amountToCover + 1, intermediate, sqrtPriceUpperX96 - clampedLower);
        }
    }

    /// @dev Values a token pair in the cheaper-token numeraire, weighting each side by its pips factor.
    function _weightedValue(
        uint256 amount0,
        uint256 amount1,
        uint256 rateX96,
        bool isToken1Cheaper,
        uint256 pipsWeight0,
        uint256 pipsWeight1
    ) private pure returns (uint256) {
        return isToken1Cheaper
            ? FullMath.mulDiv(amount0, rateX96 * pipsWeight0, FixedPoint96.Q96 * PIPS_DENOMINATOR)
                + FullMath.mulDiv(amount1, pipsWeight1, PIPS_DENOMINATOR)
            : FullMath.mulDiv(amount0, pipsWeight0, PIPS_DENOMINATOR)
                + FullMath.mulDiv(amount1, rateX96 * pipsWeight1, FixedPoint96.Q96 * PIPS_DENOMINATOR);
    }
}
