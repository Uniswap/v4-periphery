// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ImmutableState} from "./ImmutableState.sol";
import {console2} from "forge-std/console2.sol";
/// @notice Abstract contract used to sync, send, and settle funds to the pool manager
/// @dev Note that sync() is called before any erc-20 transfer in `settle`.

abstract contract DeltaResolver is ImmutableState {
    using TransientStateLibrary for IPoolManager;

    /// @notice used to signal that an action should use the input value of the open delta on the pool manager
    /// or of the balance that the contract holds
    uint128 internal constant CONTRACT_BALANCE = 0;
    uint128 internal constant OPEN_DELTA = 1;

    /// @notice Emitted trying to settle a positive delta.
    error IncorrectUseOfSettle();
    /// @notice Emitted trying to take a negative delta.
    error IncorrectUseOfTake();

    /// @notice Take an amount of currency out of the PoolManager
    /// @param currency Currency to take
    /// @param recipient Address to receive the currency
    /// @param amount Amount to take
    function _take(Currency currency, address recipient, uint256 amount) internal {
        poolManager.take(currency, recipient, amount);
    }

    /// @notice Pay and settle a currency to the PoolManager
    /// @dev The implementing contract must ensure that the `payer` is a secure address
    /// @param currency Currency to settle
    /// @param payer Address of the payer
    /// @param amount Amount to send
    function _settle(Currency currency, address payer, uint256 amount) internal {
        if (currency.isNative()) {
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            _pay(currency, payer, amount);
            poolManager.settle();
        }
    }

    /// @notice Abstract function for contracts to implement paying tokens to the poolManager
    /// @dev The recipient of the payment should be the poolManager
    /// @param token The token to settle. This is known not to be the native currency
    /// @param payer The address who should pay tokens
    /// @param amount The number of tokens to send
    function _pay(Currency token, address payer, uint256 amount) internal virtual;

    function _getFullSettleAmount(Currency currency) internal view returns (uint256 amount) {
        int256 _amount = poolManager.currencyDelta(address(this), currency);
        // If the amount is positive, it should be taken not settled for.
        if (_amount > 0) revert IncorrectUseOfSettle();
        amount = uint256(-_amount);
    }

    function _getFullTakeAmount(Currency currency) internal view returns (uint256 amount) {
        int256 _amount = poolManager.currencyDelta(address(this), currency);
        // If the amount is negative, it should be settled not taken.
        if (_amount < 0) revert IncorrectUseOfTake();
        amount = uint256(_amount);
    }

    function _mapAmount(uint256 amount, Currency currency) internal view returns (uint256) {
        console2.log("amount", amount);
        if (amount == CONTRACT_BALANCE) {
            console2.log("currency balance");
            return currency.balanceOfSelf();
        } else if (amount == OPEN_DELTA) {
            console2.log("open delta");
            return _getFullSettleAmount(currency);
        }
        return amount;
    }
}
