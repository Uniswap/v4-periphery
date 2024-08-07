// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PositionConfig} from "../libraries/PositionConfig.sol";

import {IPositionActionsRouter} from "./IPositionActionsRouter.sol";
import {IPoolInitializer} from "./IPoolInitializer.sol";
import {IPermit2Forwarder} from "./IPermit2Forwarder.sol";
import {IMulticall_v4} from "./IMulticall_v4.sol";

interface IPositionManager is IPositionActionsRouter, IPoolInitializer, IPermit2Forwarder, IMulticall_v4 {
    error DeadlinePassed();

    /// @notice Unlocks Uniswap v4 PoolManager and batches actions for modifying liquidity
    /// @dev This is the standard entrypoint for the PositionManager
    /// @param payload is an encoding of actions, and parameters for those actions
    /// @param deadline is the deadline for the batched actions to be executed
    function modifyLiquidities(bytes calldata payload, uint256 deadline) external payable;

    /// @notice Batches actions for modifying liquidity without unlocking v4 PoolManager
    /// @dev This must be called by a contract that has already unlocked the v4 PoolManager
    /// @param actions the actions to perform
    /// @param params the parameters to provide for the actions
    function modifyLiquiditiesWithoutUnlock(bytes calldata actions, bytes[] calldata params) external payable;
}
