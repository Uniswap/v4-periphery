// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {IPeripheryPayments} from "../interfaces/IPeripheryPayments.sol";

abstract contract PeripheryPayments is IPeripheryPayments {
    using CurrencyLibrary for Currency;
    using SafeTransferLib for address;
    using SafeTransferLib for ERC20;

    error InsufficientToken();
    error NativeTokenTransferFrom();

    /// @inheritdoc IPeripheryPayments
    function sweepToken(Currency currency, uint256 amountMinimum, address recipient) public payable override {
        uint256 balanceCurrency = currency.balanceOfSelf();
        if (balanceCurrency < amountMinimum) revert InsufficientToken();

        if (balanceCurrency > 0) {
            currency.transfer(recipient, balanceCurrency);
        }
    }

    /// @param currency The currency to pay
    /// @param payer The entity that must pay
    /// @param recipient The entity that will receive payment
    /// @param value The amount to pay
    function pay(Currency currency, address payer, address recipient, uint256 value) internal {
        if (payer == address(this)) {
            // pay with tokens already in the contract (for the exact input multihop case)
            currency.transfer(recipient, value);
        } else {
            if (currency.isNative()) revert NativeTokenTransferFrom();
            // pull payment
            ERC20(Currency.unwrap(currency)).safeTransferFrom(payer, recipient, value);
        }
    }
}
