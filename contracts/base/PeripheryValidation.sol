// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

error TransactionTooOld();

abstract contract PeripheryValidation {
    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert TransactionTooOld();
        _;
    }
}
