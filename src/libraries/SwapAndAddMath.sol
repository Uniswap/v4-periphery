// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";

/// @title SwapAndAddMath
/// @notice Pure sizing and trim math for SwapAndAdd. Callers supply the live sqrt price, the range
///         bounds, and the fee configuration.
library SwapAndAddMath {
    using SafeCast for uint256;

    uint256 internal constant PIPS_DENOMINATOR = 1e6;
    /// @dev Reference position used to price liquidity. Maximal, so the scale-down rounding error
    ///      is negligible.
    uint128 internal constant REFERENCE_LIQUIDITY = type(uint128).max;

    /// @notice Sizes liquidity while accounting for the swap fee on the surplus token.
    /// @dev Sizes at the mid price to find the surplus token, then discounts that token's value by
    ///      the combined pool fee. This nets to charging the fee on exactly the swapped amount.
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
            getAmountsForLiquidityRoundingUp(sqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, midLiquidity);
        if (budget0 > mid0) {
            // token0 surplus: the reconcile swap sells token0, so discount token0 by the zeroForOne fee
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
            // token1 surplus: the reconcile swap sells token1, so discount token1 by the oneForZero fee
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
        // the budget is already in exact proportion, no swap and therefore no fee discount
        return midLiquidity;
    }

    /// @notice Computes liquidity as REFERENCE_LIQUIDITY scaled by budget value over reference value.
    /// @param pipsWeight0 Value weight applied to token0, in pips.
    /// @param pipsWeight1 Value weight applied to token1, in pips.
    function getLiquidityForAmountsWeighted(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceLowerX96,
        uint160 sqrtPriceUpperX96,
        uint256 amount0,
        uint256 amount1,
        uint256 pipsWeight0,
        uint256 pipsWeight1
    ) internal pure returns (uint128) {
        // Value both tokens in whichever token is cheaper or equal, so rateX96 >= Q96 and no
        // precision is lost at extreme ticks. rateX96 is the price (sqrtPrice^2 / Q96) or its
        // inverse, split into two mulDiv steps to avoid intermediate overflow.
        bool isToken1Cheaper = sqrtPriceX96 >= FixedPoint96.Q96;
        uint256 rateX96 = isToken1Cheaper
            ? FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96)
            : FullMath.mulDiv(
                FullMath.mulDiv(FixedPoint96.Q96, FixedPoint96.Q96, sqrtPriceX96), FixedPoint96.Q96, sqrtPriceX96
            );

        uint256 refValue;
        {
            (uint256 ref0, uint256 ref1) = getAmountsForLiquidityRoundingUp(
                sqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, REFERENCE_LIQUIDITY
            );
            refValue = _tokenValue(ref0, pipsWeight0, rateX96, isToken1Cheaper)
                + _tokenValue(ref1, pipsWeight1, rateX96, !isToken1Cheaper);
        }
        if (refValue == 0) return 0;
        // L = budgetValue * REFERENCE_LIQUIDITY / refValue, truncation is safe (leftover is swept)
        uint256 budgetValue = _tokenValue(amount0, pipsWeight0, rateX96, isToken1Cheaper)
            + _tokenValue(amount1, pipsWeight1, rateX96, !isToken1Cheaper);
        return FullMath.mulDiv(budgetValue, REFERENCE_LIQUIDITY, refValue).toUint128();
    }

    /// @notice Calculates the token amounts required for a liquidity amount at the given price and range.
    /// @dev Rounds UP to mirror POSM's MINT_POSITION, so funding from these amounts is never a wei
    ///      short. Not interchangeable with LiquidityAmounts, which rounds down. The A/B bounds may
    ///      be passed in either order.
    function getAmountsForLiquidityRoundingUp(
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

    /// @notice Computes the liquidity to burn so that v4's rounded-down burn output covers
    ///         `amountToCover` of the deficit token.
    /// @dev Ceiling inverse over `amountToCover + 1`, so the freed amount is always sufficient.
    ///      Assumes the price is not past the range's far side for the deficit token.
    /// @return liquidityToTrim The liquidity to burn, uncapped. Callers must cap it against the
    ///         liquidity they added.
    function getLiquidityToTrim(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceLowerX96,
        uint160 sqrtPriceUpperX96,
        bool deficitIsCurrency1,
        uint256 amountToCover
    ) internal pure returns (uint256 liquidityToTrim) {
        if (deficitIsCurrency1) {
            // token1 occupies [sqrtLower, min(price, sqrtUpper)]: amount1 = L * (hi - lo) / Q96
            uint160 clampedUpper = sqrtPriceX96 < sqrtPriceUpperX96 ? sqrtPriceX96 : sqrtPriceUpperX96;
            liquidityToTrim =
                FullMath.mulDivRoundingUp(amountToCover + 1, FixedPoint96.Q96, clampedUpper - sqrtPriceLowerX96);
        } else {
            // token0 occupies [max(price, sqrtLower), sqrtUpper]: amount0 = L * Q96 * (hi - lo) / (hi * lo)
            uint160 clampedLower = sqrtPriceX96 > sqrtPriceLowerX96 ? sqrtPriceX96 : sqrtPriceLowerX96;
            // below tick ~-665k this quotient rounds up from below 1 and over-trims by a factor of
            // up to ~2^32 (potentially the caller's entire cap), safely absorbed without fund loss
            uint256 intermediate = FullMath.mulDivRoundingUp(clampedLower, sqrtPriceUpperX96, FixedPoint96.Q96);
            // can overflow and revert when the price is within sqrt units of sqrtUpper with a large
            // deficit (self-inflicted and atomic, a safe known limit)
            liquidityToTrim =
                FullMath.mulDivRoundingUp(amountToCover + 1, intermediate, sqrtPriceUpperX96 - clampedLower);
        }
    }

    /// @dev Values one weighted token amount; `convert` applies the rate for the non-numeraire side.
    function _tokenValue(uint256 amount, uint256 pipsWeight, uint256 rateX96, bool convert)
        private
        pure
        returns (uint256)
    {
        return convert
            ? FullMath.mulDiv(amount, rateX96 * pipsWeight, FixedPoint96.Q96 * PIPS_DENOMINATOR)
            : FullMath.mulDiv(amount, pipsWeight, PIPS_DENOMINATOR);
    }
}
