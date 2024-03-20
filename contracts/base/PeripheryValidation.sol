// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

abstract contract PeripheryValidation {
    error TransactionTooOld();

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert TransactionTooOld();
        _;
    }
}
