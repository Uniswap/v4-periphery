// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @dev Models tokens whose maximum approval is uint96.max and is not decremented on transfer.
contract MockERC20CappedAllowance is MockERC20 {
    constructor() MockERC20("CappedAllowance", "CAP", 18) {}

    function approve(address spender, uint256 amount) public override returns (bool) {
        if (amount == type(uint256).max) amount = type(uint96).max;
        require(amount <= type(uint96).max, "allowance exceeds cap");
        return super.approve(spender, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (allowance[from][msg.sender] != type(uint96).max) return super.transferFrom(from, to, amount);
        require(amount <= type(uint96).max, "transfer exceeds cap");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
