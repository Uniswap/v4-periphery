// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {PositionConfig} from "../shared/PositionConfig.sol";

library FeeMath {
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    /// @notice Calculates the fees accrued to a position. Used for testing purposes.
    function getFeesOwed(IPositionManager posm, IPoolManager manager, PositionConfig memory config, uint256 tokenId)
        internal
        view
        returns (BalanceDelta feesOwed)
    {
        PoolId poolId = config.poolKey.toId();

        // getPositionInfo(poolId, owner, tL, tU, salt)
        // owner is the position manager
        // salt is the tokenId
        (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) =
            manager.getPositionInfo(poolId, address(posm), config.tickLower, config.tickUpper, bytes32(tokenId));

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            manager.getFeeGrowthInside(poolId, config.tickLower, config.tickUpper);

        feesOwed = getFeesOwed(
            feeGrowthInside0X128, feeGrowthInside1X128, feeGrowthInside0LastX128, feeGrowthInside1LastX128, liquidity
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
