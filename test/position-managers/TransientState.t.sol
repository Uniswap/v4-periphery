// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {TransientState} from "../../contracts/libraries/TransientState.sol";

contract TransientStateLibraryTest is Test {
    MockState state;

    function setUp() public {
        state = new MockState();
    }

    function test_slot_msgSender() public {
        assertEq(
            0xa92f8f8e3c9c019e2af36d00fca6932c4fc8f6ae19d12c001041d5b2026ce1b4,
            bytes32(uint256(keccak256("MSG_SENDER_SLOT")) - 1)
        );
    }

    function test_slot_thisUnlock() public {
        assertEq(
            0x99d630d898475d0f9a470a96e8e7ee5bb2f92fdc2598801b5ea8f27960fda114,
            bytes32(uint256(keccak256("THIS_UNLOCK_SLOT")) - 1)
        );
    }

    function test_msgSender_isThis() public {
        state.setSender();
        (address addr) = state.getSender();
        assertEq(addr, address(this));
    }

    function test_unlock_isTrue() public {
        assertFalse(state.getUnlock());
        state.setUnlock(true);
        assertTrue(state.getUnlock());
    }

    function test_unlock_isFalse() public {
        assertFalse(state.getUnlock());
        state.setUnlock(true);
        assertTrue(state.getUnlock());
        state.setUnlock(false);
        assertFalse(state.getUnlock());
    }
}

contract MockState {
    function setSender() external {
        TransientState.storeMsgSender();
    }

    function getSender() external returns (address addr) {
        addr = TransientState.loadMsgSender();
    }

    function setUnlock(bool _isUnlocked) external {
        TransientState.storeUnlock(_isUnlocked);
    }

    function getUnlock() external returns (bool _isUnlocked) {
        _isUnlocked = TransientState.loadUnlock();
    }
}
