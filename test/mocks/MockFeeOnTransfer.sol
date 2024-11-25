// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {BipsLibrary} from "../../src/libraries/BipsLibrary.sol";

contract MockFOT is MockERC20 {
    using BipsLibrary for uint256;

    IPositionManager immutable posm;

    uint256 public bips;

    constructor(IPositionManager _posm) MockERC20("FOT Token", "FOT", 18) {
        posm = _posm;
    }

    function setFee(uint256 amountInBips) public {
        bips = amountInBips;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];

        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;

        balanceOf[from] -= amount;

        // bips% fee on the recipient
        uint256 amountAfterFee = amount - amount.calculatePortion(bips);

        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint256 value.
        unchecked {
            balanceOf[to] += amountAfterFee;
        }

        emit Transfer(from, to, amount);

        return true;
    }
}
