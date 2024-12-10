// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {ImmutableState} from "../base/ImmutableState.sol";
import {IStateView} from "../interfaces/IStateView.sol";

/// @notice A view only contract wrapping the StateLibrary.sol library for reading storage in v4-core.
/// @dev The contract is intended for offchain clients. Use StateLibrary.sol directly if reading state onchain.
contract StateView is ImmutableState, IStateView {
    using StateLibrary for IPoolManager;

    constructor(IPoolManager _poolManager) ImmutableState(_poolManager) {}

    /// @inheritdoc IStateView
    function getSlot0(PoolId poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        return poolManager.getSlot0(poolId);
    }

    /// @inheritdoc IStateView
    function getTickInfo(PoolId poolId, int24 tick)
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128
        )
    {
        return poolManager.getTickInfo(poolId, tick);
    }

    /// @inheritdoc IStateView
    function getTickLiquidity(PoolId poolId, int24 tick)
        external
        view
        returns (uint128 liquidityGross, int128 liquidityNet)
    {
        return poolManager.getTickLiquidity(poolId, tick);
    }

    /// @inheritdoc IStateView
    function getTickFeeGrowthOutside(PoolId poolId, int24 tick)
        external
        view
        returns (uint256 feeGrowthOutside0X128, uint256 feeGrowthOutside1X128)
    {
        return poolManager.getTickFeeGrowthOutside(poolId, tick);
    }

    /// @inheritdoc IStateView
    function getFeeGrowthGlobals(PoolId poolId)
        external
        view
        returns (uint256 feeGrowthGlobal0, uint256 feeGrowthGlobal1)
    {
        return poolManager.getFeeGrowthGlobals(poolId);
    }

    /// @inheritdoc IStateView
    function getLiquidity(PoolId poolId) external view returns (uint128 liquidity) {
        return poolManager.getLiquidity(poolId);
    }

    /// @inheritdoc IStateView
    function getTickBitmap(PoolId poolId, int16 tick) external view returns (uint256 tickBitmap) {
        return poolManager.getTickBitmap(poolId, tick);
    }

    /// @inheritdoc IStateView
    function getPositionInfo(PoolId poolId, address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        view
        returns (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128)
    {
        return poolManager.getPositionInfo(poolId, owner, tickLower, tickUpper, salt);
    }

    /// @inheritdoc IStateView
    function getPositionInfo(PoolId poolId, bytes32 positionId)
        external
        view
        returns (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128)
    {
        return poolManager.getPositionInfo(poolId, positionId);
    }

    /// @inheritdoc IStateView
    function getPositionLiquidity(PoolId poolId, bytes32 positionId) external view returns (uint128 liquidity) {
        return poolManager.getPositionLiquidity(poolId, positionId);
    }

    /// @inheritdoc IStateView
    function getFeeGrowthInside(PoolId poolId, int24 tickLower, int24 tickUpper)
        external
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        return poolManager.getFeeGrowthInside(poolId, tickLower, tickUpper);
    }
}
