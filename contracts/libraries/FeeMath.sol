// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

library FeeMath {
    using SafeCast for uint256;

    function getFeesOwed(
        uint256 feeGrowthInside0X128,
        uint256 feeGrowthInside1X128,
        uint256 feeGrowthInside0LastX128,
        uint256 feeGrowthInside1LastX128,
        uint256 liquidity
    ) internal pure returns (BalanceDelta feesOwed) {
        uint128 token0Owed = getFeeOwed(feeGrowthInside0X128, feeGrowthInside0LastX128, liquidity);
        uint128 token1Owed = getFeeOwed(feeGrowthInside1X128, feeGrowthInside1LastX128, liquidity);
        feesOwed = toBalanceDelta(uint256(token0Owed).toInt128(), uint256(token1Owed).toInt128());
    }

    function getFeeOwed(uint256 feeGrowthInsideX128, uint256 feeGrowthInsideLastX128, uint256 liquidity)
        internal
        pure
        returns (uint128 tokenOwed)
    {
        tokenOwed =
            (FullMath.mulDiv(feeGrowthInsideX128 - feeGrowthInsideLastX128, liquidity, FixedPoint128.Q128)).toUint128();
    }
}
