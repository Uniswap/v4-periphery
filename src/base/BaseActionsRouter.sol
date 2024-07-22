// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";

import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {SafeCallback} from "./SafeCallback.sol";
import {ReentrancyLock} from "./ReentrancyLock.sol";
import {Actions} from "../libraries/Actions.sol";
import {Locker} from "../libraries/Locker.sol";
import {BytesLib} from "../libraries/BytesLib.sol";

/// @notice Abstract contract for performing a combination of actions on Uniswap v4.
/// @dev If an inheriting contract does not want to support all commands, they should simply revert with the
/// UnsupportedAction error in their overriding function
/// The _msgSender function returns the msg.sender from the call to executeActions. This allows actions to know which
/// address instructed the action to be requested. The msg.sender within the unlockCallback with be the v4 PoolManager.
abstract contract BaseActionsRouter is SafeCallback, ReentrancyLock {
    using TransientStateLibrary for IPoolManager;
    using SafeTransferLib for address;
    using BytesLib for bytes;

    /// @notice emitted when different numbers of parameters and actions are provided
    error LengthMismatch();

    /// @notice emitted when an inheriting contract does not support an action
    error UnsupportedAction(uint256 action);

    constructor(IPoolManager poolManager) SafeCallback(poolManager) {}

    /// @notice internal function that triggers the execution of a set of actions on v4
    /// TODO move the reentrancy lock modifier up a level
    function _executeActions(bytes calldata params) internal isNotLocked {
        poolManager.unlock(params);
    }

    /// @notice function that is called by the PoolManager through the SafeCallback.unlockCallback
    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        // TODO would it be better to use a struct

        // abi.decode(data, (uint256[], bytes[]));
        (uint256[] calldata actions, bytes[] calldata params) = data.decodeInCalldata();

        uint256 numActions = actions.length;
        if (numActions != params.length) revert LengthMismatch();

        for (uint256 actionIndex = 0; actionIndex < numActions; actionIndex++) {
            uint256 action = actions[actionIndex];

            // separate actions on a pool for gas optimisation reasons
            if (action < Actions.SETTLE) {
                if (action == Actions.SWAP) _swap(params[actionIndex]);
                else if (action == Actions.INCREASE_LIQUIDITY) _increaseLiquidity(params[actionIndex]);
                else if (action == Actions.DECREASE_LIQUIDITY) _decreaseLiquidity(params[actionIndex]);
                else if (action == Actions.DONATE) _donate(params[actionIndex]);
                else if (action == Actions.CLEAR_DELTA) _clearDelta(params[actionIndex]);
                else revert UnsupportedAction(action);
            } else {
                if (action == Actions.SETTLE) _settle(params[actionIndex]);
                else if (action == Actions.TAKE) _take(params[actionIndex]);
                else if (action == Actions.MINT_6909) _mint6909(params[actionIndex]);
                else if (action == Actions.BURN_6909) _burn6909(params[actionIndex]);
                else revert UnsupportedAction(action);
            }
        }

        // TODO do we want to return anything?
    }

    /// @notice function that returns the msg.sender who called executeActions
    function _msgSender() internal view virtual returns (address) {
        return Locker.get();
    }

    /// @notice function to settle the open delta of a currency
    /// @dev The `_pay` function must implement necessary safety checks on the value of payer.
    /// If approvals are used on this contract, do not allow `_pay` to pull tokens from any payer.
    /// @dev The function is virtual and can be overrided if different parameters or logic are required.
    function _settle(bytes calldata params) internal virtual {
        // TODO decode in calldata
        (Currency currency, address payer) = abi.decode(params, (Currency, address));

        int256 delta = poolManager.currencyDelta(address(this), currency);
        if (delta > 0) revert();

        if (currency.isNative()) {
            poolManager.settle{value: uint256(-delta)}();
        } else {
            poolManager.sync(currency);
            _pay(currency, payer, address(poolManager), uint256(-delta));
            poolManager.settle();
        }
    }

    /// @notice abstract function to implement the payment of tokens to the pool manager during a settle
    function _pay(Currency currency, address payer, address recipient, uint256 amount) internal virtual;

    /// @notice function to take owed currency from the pool manager to a recipient
    /// @dev The function is virtual and can be overrided if different parameters or logic are required.
    function _take(bytes calldata params) internal virtual {
        // TODO decode in calldata
        (Currency currency, address recipient) = abi.decode(params, (Currency, address));

        int256 delta = poolManager.currencyDelta(address(this), currency);
        if (delta < 0) revert();

        poolManager.take(currency, recipient, uint256(delta));
    }

    function _swap(bytes calldata params) internal virtual;

    function _increaseLiquidity(bytes calldata params) internal virtual;

    function _decreaseLiquidity(bytes calldata params) internal virtual;

    function _donate(bytes calldata params) internal virtual;

    function _mint6909(bytes calldata params) internal virtual;

    function _burn6909(bytes calldata params) internal virtual;

    function _clearDelta(bytes calldata params) internal virtual;
}
