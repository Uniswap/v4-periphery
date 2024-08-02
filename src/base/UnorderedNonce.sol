// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {UnorderedNonceLibrary} from "../libraries/UnorderedNonceLibrary.sol";

/// @title Unordered Nonce
/// @notice Contract state and methods for using unordered nonces in signatures
contract UnorderedNonce {
    using UnorderedNonceLibrary for *;

    mapping(address owner => mapping(uint256 word => uint256 bitmap)) public nonces;

    /// @notice Consume a nonce, reverting if its already been used
    /// @param owner address, the owner/signer of the nonce
    /// @param nonce uint256, the nonce to consume
    function _useUnorderedNonce(address owner, uint256 nonce) internal {
        (uint256 wordPos, uint256 bitPos) = nonce.getBitmapPositions();
        nonces[owner].flipBit(wordPos, bitPos);
    }
}
