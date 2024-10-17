// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IWETH9} from "../interfaces/external/IWETH9.sol";
import {ActionConstants} from "../libraries/ActionConstants.sol";

/// @title Native Wrapper
/// @notice Allows wrapping and unwrapping of native tokens before or after adding/removing liquidity
contract NativeWrapper {
    IWETH9 public immutable WETH9;

    constructor(IWETH9 _weth9) {
        WETH9 = _weth9;
    }

    function wrap(uint256 _amount) external payable {
        uint256 amount = _amount == ActionConstants.CONTRACT_BALANCE ? address(this).balance : _amount;
        WETH9.deposit{value: amount}();
    }

    /// @dev payable so it can be multicalled
    function unwrap(uint256 _amount) external payable {
        uint256 amount = _amount == ActionConstants.CONTRACT_BALANCE ? WETH9.balanceOf(address(this)) : _amount;
        WETH9.withdraw(amount);
    }
}
