// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IWETH9} from "../interfaces/external/IWETH9.sol";
import {ActionConstants} from "../libraries/ActionConstants.sol";

/// @title Native Wrapper
/// @notice Immutables and helpers for wrapping and unwrapping native
contract NativeWrapper {
    IWETH9 public immutable WETH9;

    error InsufficientBalance();

    constructor(IWETH9 _weth9) {
        WETH9 = _weth9;
    }

    function _map(uint256 amount, uint256 balance) internal pure returns (uint256) {
        if (amount == ActionConstants.CONTRACT_BALANCE) return balance;
        if (amount > balance) revert InsufficientBalance();
        return amount;
    }

    receive() external payable {}
}
