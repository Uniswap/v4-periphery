// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {IPositionManager} from "./interfaces/IPositionManager.sol";
import {PositionActionsRouter} from "./base/PositionActionsRouter.sol";
import {PoolInitializer} from "./base/PoolInitializer.sol";
import {Permit2Forwarder} from "./base/Permit2Forwarder.sol";
import {Multicall_v4} from "./base/Multicall_v4.sol";

contract PositionManager is IPositionManager, PositionActionsRouter, PoolInitializer, Permit2Forwarder, Multicall_v4 {
    constructor(IPoolManager _poolManager, IAllowanceTransfer _permit2) PositionActionsRouter(_poolManager, _permit2) {}

    /// @inheritdoc IPositionManager
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline)
        external
        payable
        isNotLocked
        checkDeadline(deadline)
    {
        _executeActions(unlockData);
    }

    /// @inheritdoc IPositionManager
    function modifyLiquiditiesWithoutUnlock(bytes calldata actions, bytes[] calldata params)
        external
        payable
        isNotLocked
    {
        _executeActionsWithoutUnlock(actions, params);
    }

    /// @notice Reverts if the deadline has passed
    /// @param deadline The timestamp at which the call is no longer valid, passed in by the caller
    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert(); // TODO: error DeadlinePassed();
        _;
    }
}
