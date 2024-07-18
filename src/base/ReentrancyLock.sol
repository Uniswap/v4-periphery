// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {Locker} from "../libraries/Locker.sol";

contract ReentrancyLock {
    error ContractLocked();

    modifier isNotLocked() {
        if (Locker.get() != address(0)) revert ContractLocked();
        Locker.set(msg.sender);
        _;
        Locker.set(address(0));
    }
}
