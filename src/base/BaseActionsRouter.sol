// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SafeCallback} from "./SafeCallback.sol";
import {CalldataDecoder} from "../libraries/CalldataDecoder.sol";

/// @notice Abstract contract for performing a combination of actions on Uniswap v4.
/// @dev Suggested uint256 action values are defined in Actions.sol, however any definition can be used
abstract contract BaseActionsRouter is SafeCallback {
    using CalldataDecoder for bytes;

    /// @notice emitted when different numbers of parameters and actions are provided
    error LengthMismatch();

    /// @notice emitted when an inheriting contract does not support an action
    error UnsupportedAction(uint256 action);

    constructor(IPoolManager _poolManager) SafeCallback(_poolManager) {}

    /// @notice internal function that triggers the execution of a set of actions on v4
    /// @dev inheriting contracts should call this function to trigger execution
    function _executeActions(bytes calldata params) internal {
        poolManager.unlock(params);
    }

    /// @notice function that is called by the PoolManager through the SafeCallback.unlockCallback
    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        // abi.decode(data, (uint256[], bytes[]));
        (uint256[] calldata actions, bytes[] calldata params) = data.decodeActionsRouterParams();

        uint256 numActions = actions.length;
        if (numActions != params.length) revert LengthMismatch();

        for (uint256 actionIndex = 0; actionIndex < numActions; actionIndex++) {
            uint256 action = actions[actionIndex];

            _handleAction(action, params[actionIndex]);
        }

        // TODO do we want to return anything?
        return "";
    }

    /// @notice function to handle the parsing and execution of an action and its parameters
    function _handleAction(uint256 action, bytes calldata params) internal virtual;

    /// @notice function that returns address considered executer of the actions
    /// @dev The other context functions, _msgData and _msgValue, are not supported by this contract
    /// In many contracts this will be the address that calls the initial entry point that calls `_executeActions`
    /// `msg.sender` shouldnt be used, as this will be the v4 pool manager contract that calls `unlockCallback`
    /// If using ReentrancyLock.sol, this function can return Locker.get() - locker of the contract
    function _msgSender() internal view virtual returns (address);
}
