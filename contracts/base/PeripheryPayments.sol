// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Minimal} from "@uniswap/v4-core/contracts/interfaces/external/IERC20Minimal.sol";

import {IPeripheryPayments} from "../interfaces/IPeripheryPayments.sol";

import "../libraries/TransferHelper.sol";

error InsufficientToken();

abstract contract PeripheryPayments is IPeripheryPayments {
    /// @inheritdoc IPeripheryPayments
    function sweepToken(address token, uint256 amountMinimum, address recipient) public payable override {
        uint256 balanceToken = IERC20(token).balanceOf(address(this));
        if (balanceToken < amountMinimum) revert InsufficientToken();

        if (balanceToken > 0) {
            TransferHelper.safeTransfer(IERC20Minimal(token), recipient, balanceToken);
        }
    }

    /// @inheritdoc IPeripheryPayments
    function refundETH() external payable override {
        if (address(this).balance > 0) TransferHelper.safeTransferETH(msg.sender, address(this).balance);
    }

    /// @param token The token to pay
    /// @param payer The entity that must pay
    /// @param recipient The entity that will receive payment
    /// @param value The amount to pay
    function pay(address token, address payer, address recipient, uint256 value) internal {
        if (payer == address(this)) {
            // pay with tokens already in the contract (for the exact input multihop case)
            TransferHelper.safeTransfer(IERC20Minimal(token), recipient, value);
        } else {
            // pull payment
            TransferHelper.safeTransferFrom(IERC20Minimal(token), payer, recipient, value);
        }
    }
}
