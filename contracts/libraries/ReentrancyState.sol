// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

library ReentrancyState {
    // bytes32(uint256(keccak256("ReentrancyState")) - 1)
    bytes32 constant REENTRANCY_STATE_SLOT = 0xbedc9a60a226d4ae7b727cbc828f66c94c4eead57777428ceab2f04b0efca3a5;

    function unlock() internal {
        assembly {
            tstore(REENTRANCY_STATE_SLOT, 0)
        }
    }

    function lockSwap() internal {
        assembly {
            tstore(REENTRANCY_STATE_SLOT, 1)
        }
    }

    function lockSwapRemove() internal {
        assembly {
            tstore(REENTRANCY_STATE_SLOT, 2)
        }
    }

    function read() internal view returns (uint256 state) {
        assembly {
            state := tload(REENTRANCY_STATE_SLOT)
        }
    }

    function swapLocked() internal view returns (bool) {
        return read() == 1 || read() == 2;
    }

    function removeLocked() internal view returns (bool) {
        return read() == 2;
    }
}
