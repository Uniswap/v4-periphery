// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

library TransientState {
    // uint256(keccak256("MSG_SENDER_SLOT") - 1)
    bytes32 internal constant MSG_SENDER_SLOT = 0xa92f8f8e3c9c019e2af36d00fca6932c4fc8f6ae19d12c001041d5b2026ce1b4;

    // uint256(keccak256("THIS_UNLOCK_SLOT") - 1)
    bytes32 internal constant THIS_UNLOCK_SLOT = 0x99d630d898475d0f9a470a96e8e7ee5bb2f92fdc2598801b5ea8f27960fda114;

    function storeMsgSender() internal {
        bytes32 slot = MSG_SENDER_SLOT;
        address _msgSender = msg.sender;
        assembly {
            tstore(slot, _msgSender)
        }
    }

    function loadMsgSender() internal view returns (address _msgSender) {
        bytes32 slot = MSG_SENDER_SLOT;
        assembly {
            _msgSender := tload(slot)
        }
    }

    function storeUnlock(bool _isUnlocked) internal {
        bytes32 slot = THIS_UNLOCK_SLOT;
        assembly {
            tstore(slot, _isUnlocked)
        }
    }

    function loadUnlock() internal returns (bool _isUnlocked) {
        bytes32 slot = THIS_UNLOCK_SLOT;
        assembly {
            _isUnlocked := tload(slot)
        }
    }
}
