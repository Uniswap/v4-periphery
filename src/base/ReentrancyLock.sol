// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {Locker} from "../libraries/Locker.sol";

/// @notice A transient reentrancy lock, that stores the caller's address as the lock
contract ReentrancyLock {
    error ContractLocked();

    modifier isNotLocked() {
        if (Locker.get() != address(0)) revert ContractLocked();
        Locker.set(msg.sender);
        _;
        Locker.set(address(0));
    }

    function _getLocker() internal view returns (address) {
        return Locker.get();
    }
}
