// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {INonfungiblePositionManager} from "../../src/interfaces/INonfungiblePositionManager.sol";
import {NonfungiblePositionManager} from "../../src/NonfungiblePositionManager.sol";
import {LiquidityRange} from "../../src/types/LiquidityRange.sol";

library FeeMath {
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using PoolIdLibrary for PoolKey;

    /// @notice Calculates the fees accrued to a position. Used for testing purposes.
    function getFeesOwed(INonfungiblePositionManager posm, IPoolManager manager, uint256 tokenId)
        internal
        view
        returns (BalanceDelta feesOwed)
    {
        (, LiquidityRange memory range,) = posm.tokenPositions(tokenId);

        // getPosition(poolId, owner, tL, tU, salt)
        // owner is the position manager
        // salt is the tokenId
        Position.Info memory position =
            manager.getPosition(range.poolKey.toId(), address(posm), range.tickLower, range.tickUpper, bytes32(tokenId));

        (uint256 feeGrowthInside0X218, uint256 feeGrowthInside1X128) =
            manager.getFeeGrowthInside(range.poolKey.toId(), range.tickLower, range.tickUpper);

        feesOwed = getFeesOwed(
            feeGrowthInside0X218,
            feeGrowthInside1X128,
            position.feeGrowthInside0LastX128,
            position.feeGrowthInside1LastX128,
            position.liquidity
        );
    }

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
