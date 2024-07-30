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
        (uint256 wordPos, uint256 bitPos) = bitmapPositions(nonce);
        uint256 bit = 1 << bitPos;
        uint256 flipped = nonces[owner][wordPos] ^= bit;

        if (flipped & bit == 0) revert NonceAlreadyUsed();
    }

    /// @notice Returns the index of the bitmap and the bit position within the bitmap. Used for unordered nonces
    /// @param nonce The nonce to get the associated word and bit positions
    /// @return wordPos The word position or index into the nonceBitmap
    /// @return bitPos The bit position
    /// @dev The first 248 bits of the nonce value is the index of the desired bitmap
    /// @dev The last 8 bits of the nonce value is the position of the bit in the bitmap
    function bitmapPositions(uint256 nonce) private pure returns (uint256 wordPos, uint256 bitPos) {
        wordPos = uint248(nonce >> 8);
        bitPos = uint8(nonce);
    }
}
