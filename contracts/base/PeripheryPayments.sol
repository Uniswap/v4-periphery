// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Minimal} from "@uniswap/v4-core/contracts/interfaces/external/IERC20Minimal.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {IPeripheryPayments} from "../interfaces/IPeripheryPayments.sol";
import {TransferHelper} from "../libraries/TransferHelper.sol";

using CurrencyLibrary for Currency;
using TransferHelper for address;
using TransferHelper for IERC20Minimal;

error InsufficientToken();

abstract contract PeripheryPayments is IPeripheryPayments {
    /// @inheritdoc IPeripheryPayments
    function sweepToken(Currency currency, uint256 amountMinimum, address recipient) public payable override {
        uint256 balanceCurrency = currency.balanceOfSelf();
        if (balanceCurrency < amountMinimum) revert InsufficientToken();

        if (balanceCurrency > 0) {
            currency.transfer(recipient, balanceCurrency);
        }
    }

    /// @param token The token to pay
    /// @param payer The entity that must pay
    /// @param recipient The entity that will receive payment
    /// @param value The amount to pay
    function pay(address token, address payer, address recipient, uint256 value) internal {
        if (payer == address(this)) {
            // pay with tokens already in the contract (for the exact input multihop case)
            IERC20Minimal(token).safeTransfer(recipient, value);
        } else {
            // pull payment
            IERC20Minimal(token).safeTransferFrom(payer, recipient, value);
        }
    }
}
