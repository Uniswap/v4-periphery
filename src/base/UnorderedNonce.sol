// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/// @title Unordered Nonce
/// @notice Contract state and methods for using unordered nonces in signatures
contract UnorderedNonce {
    error NonceAlreadyUsed();

    mapping(address owner => mapping(uint256 word => uint256 bitmap)) public nonces;

    /// @notice Consume a nonce, reverting if its already been used
    /// @param owner address, the owner/signer of the nonce
    /// @param nonce uint256, the nonce to consume
    function _useUnorderedNonce(address owner, uint256 nonce) internal {
        // consume the bit by flipping it in storage
        // reverts if the bit was already spent
        _flipBit(nonces[owner], nonce);
    }

    function _flipBit(mapping(uint256 => uint256) storage bitmap, uint256 nonce) private {
        // equivalent to:
        //   uint256 wordPos = uint248(nonce >> 8);
        //   uint256 bitPos = uint8(nonce);
        //   uint256 bit = 1 << bitPos;
        //   uint256 flipped = nonces[owner][wordPos] ^= bit;
        //   if (flipped & bit == 0) revert NonceAlreadyUsed();

        assembly ("memory-safe") {
            // wordPos = uint248(nonce >> 8)
            let wordPos := shr(8, nonce)

            // bit = 1 << uint8(nonce)
            let bit := shl(and(nonce, 0xFF), 1)

            // slot of bitmap[wordPos] is keccak256(abi.encode(wordPos, bitmap.slot))
            mstore(0, wordPos)
            mstore(0x20, bitmap.slot)
            let slot := keccak256(0, 0x40)

            // uint256 previousBits = bitmap[wordPos]
            let previousBits := sload(slot)

            // revert if it's already been used
            if eq(and(previousBits, bit), bit) {
                mstore(0, 0x1fb09b80) // 4 bytes of NonceAlreadyUsed.selector
                revert(0x1c, 0x04)
            }

            // bitmap[wordPos] = (previousBits | bit)
            sstore(slot, or(previousBits, bit))
        }
    }
}
