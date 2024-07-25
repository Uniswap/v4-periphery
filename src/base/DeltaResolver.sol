// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ImmutableState} from "./ImmutableState.sol";

/// @notice Abstract contract used to sync, send, and settle funds to the pool manager
/// @dev Note that sync() is called before any erc-20 transfer in `settle`.
abstract contract DeltaResolver is ImmutableState {
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
}
