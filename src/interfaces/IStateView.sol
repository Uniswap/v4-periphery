// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {IImmutableState} from "../interfaces/IImmutableState.sol";

/// @title IStateView
/// @notice Interface for the StateView contract
interface IStateView is IImmutableState {
    /// @notice Get Slot0 of the pool: sqrtPriceX96, tick, protocolFee, lpFee
    /// @dev Corresponds to pools[poolId].slot0
    /// @param poolId The ID of the pool.
    /// @return sqrtPriceX96 The square root of the price of the pool, in Q96 precision.
    /// @return tick The current tick of the pool.
    /// @return protocolFee The protocol fee of the pool.
    /// @return lpFee The swap fee of the pool.
    function getSlot0(PoolId poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);

    /// @notice Retrieves the tick information of a pool at a specific tick.
    /// @dev Corresponds to pools[poolId].ticks[tick]
    /// @param poolId The ID of the pool.
    /// @param tick The tick to retrieve information for.
    /// @return liquidityGross The total position liquidity that references this tick
    /// @return liquidityNet The amount of net liquidity added (subtracted) when tick is crossed from left to right (right to left)
    /// @return feeGrowthOutside0X128 fee growth per unit of liquidity on the _other_ side of this tick (relative to the current tick)
    /// @return feeGrowthOutside1X128 fee growth per unit of liquidity on the _other_ side of this tick (relative to the current tick)
    function getTickInfo(PoolId poolId, int24 tick)
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128
        );

    /// @notice Retrieves the liquidity information of a pool at a specific tick.
    /// @dev Corresponds to pools[poolId].ticks[tick].liquidityGross and pools[poolId].ticks[tick].liquidityNet. A more gas efficient version of getTickInfo
    /// @param poolId The ID of the pool.
    /// @param tick The tick to retrieve liquidity for.
    /// @return liquidityGross The total position liquidity that references this tick
    /// @return liquidityNet The amount of net liquidity added (subtracted) when tick is crossed from left to right (right to left)
    function getTickLiquidity(PoolId poolId, int24 tick)
        external
        view
        returns (uint128 liquidityGross, int128 liquidityNet);

    /// @notice Retrieves the fee growth outside a tick range of a pool
    /// @dev Corresponds to pools[poolId].ticks[tick].feeGrowthOutside0X128 and pools[poolId].ticks[tick].feeGrowthOutside1X128. A more gas efficient version of getTickInfo
    /// @param poolId The ID of the pool.
    /// @param tick The tick to retrieve fee growth for.
    /// @return feeGrowthOutside0X128 fee growth per unit of liquidity on the _other_ side of this tick (relative to the current tick)
    /// @return feeGrowthOutside1X128 fee growth per unit of liquidity on the _other_ side of this tick (relative to the current tick)
    function getTickFeeGrowthOutside(PoolId poolId, int24 tick)
        external
        view
        returns (uint256 feeGrowthOutside0X128, uint256 feeGrowthOutside1X128);

    /// @notice Retrieves the global fee growth of a pool.
    /// @dev Corresponds to pools[poolId].feeGrowthGlobal0X128 and pools[poolId].feeGrowthGlobal1X128
    /// @param poolId The ID of the pool.
    /// @return feeGrowthGlobal0 The global fee growth for token0.
    /// @return feeGrowthGlobal1 The global fee growth for token1.
    function getFeeGrowthGlobals(PoolId poolId)
        external
        view
        returns (uint256 feeGrowthGlobal0, uint256 feeGrowthGlobal1);

    /// @notice Retrieves the total liquidity of a pool.
    /// @dev Corresponds to pools[poolId].liquidity
    /// @param poolId The ID of the pool.
    /// @return liquidity The liquidity of the pool.
    function getLiquidity(PoolId poolId) external view returns (uint128 liquidity);

    /// @notice Retrieves the tick bitmap of a pool at a specific tick.
    /// @dev Corresponds to pools[poolId].tickBitmap[tick]
    /// @param poolId The ID of the pool.
    /// @param tick The tick to retrieve the bitmap for.
    /// @return tickBitmap The bitmap of the tick.
    function getTickBitmap(PoolId poolId, int16 tick) external view returns (uint256 tickBitmap);

    /// @notice Retrieves the position info without needing to calculate the `positionId`.
    /// @dev Corresponds to pools[poolId].positions[positionId]
    /// @param poolId The ID of the pool.
    /// @param owner The owner of the liquidity position.
    /// @param tickLower The lower tick of the liquidity range.
    /// @param tickUpper The upper tick of the liquidity range.
    /// @param salt The bytes32 randomness to further distinguish position state.
    /// @return liquidity The liquidity of the position.
    /// @return feeGrowthInside0LastX128 The fee growth inside the position for token0.
    /// @return feeGrowthInside1LastX128 The fee growth inside the position for token1.
    function getPositionInfo(PoolId poolId, address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        view
        returns (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128);

    /// @notice Retrieves the position information of a pool at a specific position ID.
    /// @dev Corresponds to pools[poolId].positions[positionId]
    /// @param poolId The ID of the pool.
    /// @param positionId The ID of the position.
    /// @return liquidity The liquidity of the position.
    /// @return feeGrowthInside0LastX128 The fee growth inside the position for token0.
    /// @return feeGrowthInside1LastX128 The fee growth inside the position for token1.
    function getPositionInfo(PoolId poolId, bytes32 positionId)
        external
        view
        returns (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128);

    /// @notice Retrieves the liquidity of a position.
    /// @dev Corresponds to pools[poolId].positions[positionId].liquidity. More gas efficient for just retrieving liquidity as compared to getPositionInfo
    /// @param poolId The ID of the pool.
    /// @param positionId The ID of the position.
    /// @return liquidity The liquidity of the position.
    function getPositionLiquidity(PoolId poolId, bytes32 positionId) external view returns (uint128 liquidity);

    /// @notice Calculate the fee growth inside a tick range of a pool
    /// @dev pools[poolId].feeGrowthInside0LastX128 in Position.Info is cached and can become stale. This function will calculate the up to date feeGrowthInside
    /// @param poolId The ID of the pool.
    /// @param tickLower The lower tick of the range.
    /// @param tickUpper The upper tick of the range.
    /// @return feeGrowthInside0X128 The fee growth inside the tick range for token0.
    /// @return feeGrowthInside1X128 The fee growth inside the tick range for token1.
    function getFeeGrowthInside(PoolId poolId, int24 tickLower, int24 tickUpper)
        external
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128);
}
