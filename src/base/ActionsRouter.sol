// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SafeCallback} from "./SafeCallback.sol";
import {ReentrancyLock} from "./ReentrancyLock.sol";
import {Actions} from "../libraries/Actions.sol";
import {Locker} from "../libraries/Locker.sol";

/// @notice Abstract contract for performing a combination of actions on Uniswap v4.
/// @dev If an inheriting contract does not want to support all commands, they should simply revert with the
/// UnsupportedAction error in their overriding function
/// If additional actions are required, define new unique action constants, and implement the logic for handling them
/// in the `_handleAdditionalActions{1/2}` functions
/// The _msgSender function returns the msg.sender from the call to executeActions. This allows actions to know which
/// address instructed the action to be requested. The msg.sender within the unlockCallback with be the v4 PoolManager.
abstract contract BaseActionsRouter is SafeCallback, ReentrancyLock {
    /// @notice emitted when different numbers of parameters and actions are provided
    error LengthMismatch();
    error UnsupportedAction();

    constructor(IPoolManager poolManager) SafeCallback(poolManager) {}

    function executeActions(bytes calldata params) external payable isNotLocked {
        poolManager.unlock(params);
    }

    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        (uint256[] memory actions, bytes[] memory params) = abi.decode(data, (uint256[], bytes[]));

        uint256 numActions = actions.length;
        if (numActions != params.length) revert LengthMismatch();

        for (uint256 actionIndex = 0; actionIndex < numActions; actionIndex++) {
            uint256 action = actions[actionIndex];

            // separate actions on a pool, and settling deltas
            if (action < 0x10) {
                if (action == Actions.SWAP) _swap(params[actionIndex]);
                else if (action == Actions.INCREASE_LIQUIDITY) _increaseLiquidity(params[actionIndex]);
                else if (action == Actions.DECREASE_LIQUIDITY) _decreaseLiquidity(params[actionIndex]);
                else if (action == Actions.MINT_POSITION) _mintPosition(params[actionIndex]);
                else if (action == Actions.BURN_POSITION) _burnPosition(params[actionIndex]);
                else if (action == Actions.DONATE) _donate(params[actionIndex]);
                else _handleAdditionalActions2(action, params[actionIndex]);
            } else {
                if (action == Actions.SETTLE) _settle(params[actionIndex]);
                else if (action == Actions.TAKE) _take(params[actionIndex]);
                else if (action == Actions.MINT_6909) _mint6909(params[actionIndex]);
                else if (action == Actions.BURN_6909) _burn6909(params[actionIndex]);
                else if (action == Actions.CLEAR_DELTA) _clearDelta(params[actionIndex]);
                else if (action == Actions.SWEEP_ETH) _sweepETH(params[actionIndex]);
                else _handleAdditionalActions2(action, params[actionIndex]);
            }
        }
    }

    // Internal function that returns the msg.sender who called executeActions
    function _msgSender() internal view virtual returns (address) {
        return Locker.get();
    }

    /// @notice Internal settle function to settle the open delta of a currency
    /// @dev The `_pay` function must implement necessary safety checks on the value of payer.
    /// If approvals are used on this contract, do not allow `_pay` to pull tokens from any payer.
    /// @dev The function is virtual and can be overrided if different parameters or logic are required.
    function _settle(bytes calldata params) internal virtual {
        // abi.decode(params, (Currency, payer))
        Currency currency;
        address payer;
        assembly {
            currency := calldataload(params.offset)
            payer := calldataload(add(params.offset, 0x20))
        }

        int256 delta = poolManager.currencyDelta(address(this), currency);
        if (delta > 0) revert();

        if (currency.isNative()) {
            poolManager.settle({value: uint256(-settleAmount)});
        } else {
            poolManager.sync(currency);
            _pay(currency, payer, address(poolManager), uint256(-settleAmount));
            poolManager.settle();
        }
    }

    /// @notice abstract function to implement the payment of tokens to the pool manager
    function _pay(Currency currency, address payer, address recipient, uint256 amount) internal virtual;

    /// @notice Internal take function to take owed currency from the pool manager to a recipient
    /// @dev The function is virtual and can be overrided if different parameters or logic are required.
    function _take(bytes calldata params) internal virtual {
        // abi.decode(params, (Currency, address))
        Currency currency;
        address recipient;
        assembly {
            currency := calldataload(params.offset)
            recipient := calldataload(add(params.offset, 0x20))
        }

        int256 delta = poolManager.currencyDelta(address(this), currency);
        if (delta < 0) revert();

        poolManager.take(currency, recipient, uint256(delta));
    }

    /// @notice function to sweep any excess ETH back to a recipient
    function _sweepETH(bytes calldata params) internal virtual {
        // abi.decode(params, (address))
        address payable recipient;
        assembly {
            recipient := calldataload(params.offset, 0x20)
        }

        balance = address(this).balance;
        if (balance > 0) recipient.safeTransferETH(balance);
    }

    function _swap(bytes calldata params) internal virtual;

    function _increaseLiquidity(bytes calldata params) internal virtual;

    function _decreaseLiquidity(bytes calldata params) internal virtual;

    function _mintPosition(bytes calldata params) internal virtual;

    function _burnPosition(bytes calldata params) internal virtual;

    function _donate(bytes calldata params) internal virtual;

    function _mint6909(bytes calldata params) internal virtual;

    function _burn6909(bytes calldata params) internal virtual;

    function _clearDelta(bytes calldata params) internal virtual;

    function _handleAdditionalActions1(uint256 action, bytes calldata params) internal virtual;

    function _handleAdditionalActions2(uint256 action, bytes calldata params) internal virtual;
}
