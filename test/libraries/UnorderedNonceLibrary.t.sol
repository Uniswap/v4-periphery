// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {UnorderedNonceLibrary} from "../../src/libraries/UnorderedNonceLibrary.sol";

contract UnorderedNonceLibraryTest is Test {
    using UnorderedNonceLibrary for *;

    mapping(uint256 word => uint256 bitmap) public nonces0;
    mapping(uint256 word => uint256 bitmap) public nonces1;

    /// @dev test getBitmapPositions() is returning the correct word and bit positions
    function test_getBitmapPositions(uint256 nonce) public pure {
        (uint256 wordPos, uint256 bitPos) = nonce.getBitmapPositions();

        assertEq(wordPos, nonce >> 8);
        assertEq(bitPos, nonce & 0xFF);
    }

    /// @dev test flipBit() is changing the bit as expected
    function test_flipBit(uint256 nonce) public {
        (uint256 wordPos, uint256 bitPos) = nonce.getBitmapPositions();
        nonces0.flipBit(wordPos, bitPos);

        uint256 bit = 1 << bitPos;
        assertEq(nonces0[wordPos], bit);
    }

    /// @dev test flipBit()'s assembly is equivalent to manually flipping the bit
    function test_flipBit_equivalence(uint256 nonce) public {
        (uint256 wordPos0, uint256 bitPos0) = nonce.getBitmapPositions();
        nonces0.flipBit(wordPos0, bitPos0);

        // manually flip nonce without assembly
        (uint256 wordPos1, uint256 bitPos1) = _flipNonce(nonce);

        assertEq(wordPos0, wordPos1);
        assertEq(bitPos0, bitPos1);
        assertEq(nonces0[wordPos0], nonces1[wordPos1]);
    }

    function _flipNonce(uint256 nonce) internal returns (uint256 wordPos, uint256 bitPos) {
        wordPos = nonce >> 8;
        bitPos = uint8(nonce);

        uint256 bit = 1 << bitPos;
        nonces1[wordPos] ^= bit;
    }
}
