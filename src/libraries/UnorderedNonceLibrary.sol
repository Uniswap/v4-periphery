// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/// @title Unordered Nonce
/// @notice Contract state and methods for using unordered nonces in signatures
library UnorderedNonceLibrary {
    error NonceAlreadyUsed();

    /// @notice Given an unordered nonce, return the word and bit position to set in a bitmap
    function getBitmapPositions(uint256 nonce) internal pure returns (uint256 wordPos, uint256 bitPos) {
        assembly {
            wordPos := shr(8, nonce)
            bitPos := and(nonce, 0xFF)
        }
    }

    /// @notice Flip a bit in a bitmap, reverting if the bit was already set
    function flipBit(mapping(uint256 => uint256) storage self, uint256 wordPos, uint256 bitPos) internal {
        // equivalent to:
        //   uint256 bit = 1 << bitPos;
        //   uint256 flipped = nonces[owner][wordPos] ^= bit;
        //   if (flipped & bit == 0) revert NonceAlreadyUsed();

        assembly ("memory-safe") {
            // slot of self[wordPos] is keccak256(abi.encode(wordPos, self.slot))
            mstore(0, wordPos)
            mstore(0x20, self.slot)
            let slot := keccak256(0, 0x40)

            // uint256 previousBits = self[wordPos]
            let previousBits := sload(slot)

            // bit = 1 << bitPos
            let bit := shl(bitPos, 1)

            // revert if it's already been used
            if eq(and(previousBits, bit), bit) {
                mstore(0, 0x1fb09b80) // 4 bytes of NonceAlreadyUsed.selector
                revert(0x1c, 0x04)
            }

            // self[wordPos] = (previousBits | bit)
            sstore(slot, or(previousBits, bit))
        }
    }
}
