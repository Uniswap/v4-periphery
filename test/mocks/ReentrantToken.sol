// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";

contract ReentrantToken is MockERC20 {
    IPositionManager immutable posm;

    constructor(IPositionManager _posm) MockERC20("Reentrant Token", "RT", 18) {
        posm = _posm;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        // we dont need data because itll revert before it does anything
        posm.modifyLiquidities("", type(uint256).max);
        return true;
    }
}
