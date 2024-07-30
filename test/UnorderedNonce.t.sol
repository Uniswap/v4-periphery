// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {UnorderedNonce} from "../src/base/UnorderedNonce.sol";
import {MockUnorderedNonce} from "./mocks/MockUnorderedNonce.sol";

contract UnorderedNonceTest is Test {
    MockUnorderedNonce unorderedNonce;

    function setUp() public {
        unorderedNonce = new MockUnorderedNonce();
    }

    function testLowNonces() public {
        unorderedNonce.spendNonce(address(this), 5);
        unorderedNonce.spendNonce(address(this), 0);
        unorderedNonce.spendNonce(address(this), 1);

        vm.expectRevert(UnorderedNonce.NonceAlreadyUsed.selector);
        unorderedNonce.spendNonce(address(this), 1);
        vm.expectRevert(UnorderedNonce.NonceAlreadyUsed.selector);
        unorderedNonce.spendNonce(address(this), 5);
        vm.expectRevert(UnorderedNonce.NonceAlreadyUsed.selector);
        unorderedNonce.spendNonce(address(this), 0);
        unorderedNonce.spendNonce(address(this), 4);
    }

    function testNonceWordBoundary() public {
        unorderedNonce.spendNonce(address(this), 255);
        unorderedNonce.spendNonce(address(this), 256);

        vm.expectRevert(UnorderedNonce.NonceAlreadyUsed.selector);
        unorderedNonce.spendNonce(address(this), 255);
        vm.expectRevert(UnorderedNonce.NonceAlreadyUsed.selector);
        unorderedNonce.spendNonce(address(this), 256);
    }

    function testHighNonces() public {
        unorderedNonce.spendNonce(address(this), 2 ** 240);
        unorderedNonce.spendNonce(address(this), 2 ** 240 + 1);

        vm.expectRevert(UnorderedNonce.NonceAlreadyUsed.selector);
        unorderedNonce.spendNonce(address(this), 2 ** 240);
        vm.expectRevert(UnorderedNonce.NonceAlreadyUsed.selector);
        unorderedNonce.spendNonce(address(this), 2 ** 240 + 1);

        unorderedNonce.spendNonce(address(this), 2 ** 240 + 2);
    }

    function testInvalidateFullWord() public {
        unorderedNonce.invalidateUnorderedNonces(0, 2 ** 256 - 1);

        vm.expectRevert(UnorderedNonce.NonceAlreadyUsed.selector);
        unorderedNonce.spendNonce(address(this), 0);
        vm.expectRevert(UnorderedNonce.NonceAlreadyUsed.selector);
        unorderedNonce.spendNonce(address(this), 1);
        vm.expectRevert(UnorderedNonce.NonceAlreadyUsed.selector);
        unorderedNonce.spendNonce(address(this), 254);
        vm.expectRevert(UnorderedNonce.NonceAlreadyUsed.selector);
        unorderedNonce.spendNonce(address(this), 255);
        unorderedNonce.spendNonce(address(this), 256);
    }

    function testInvalidateNonzeroWord() public {
        unorderedNonce.invalidateUnorderedNonces(1, 2 ** 256 - 1);

        unorderedNonce.spendNonce(address(this), 0);
        unorderedNonce.spendNonce(address(this), 254);
        unorderedNonce.spendNonce(address(this), 255);
        vm.expectRevert(UnorderedNonce.NonceAlreadyUsed.selector);
        unorderedNonce.spendNonce(address(this), 256);
        vm.expectRevert(UnorderedNonce.NonceAlreadyUsed.selector);
        unorderedNonce.spendNonce(address(this), 511);
        unorderedNonce.spendNonce(address(this), 512);
    }

    function testUsingNonceTwiceFails(uint256 nonce) public {
        unorderedNonce.spendNonce(address(this), nonce);
        vm.expectRevert(UnorderedNonce.NonceAlreadyUsed.selector);
        unorderedNonce.spendNonce(address(this), nonce);
    }

    function testUseTwoRandomNonces(uint256 first, uint256 second) public {
        unorderedNonce.spendNonce(address(this), first);
        if (first == second) {
            vm.expectRevert(UnorderedNonce.NonceAlreadyUsed.selector);
            unorderedNonce.spendNonce(address(this), second);
        } else {
            unorderedNonce.spendNonce(address(this), second);
        }
    }

    function testInvalidateNoncesRandomly(uint248 wordPos, uint256 mask) public {
        unorderedNonce.invalidateUnorderedNonces(wordPos, mask);
        assertEq(mask, unorderedNonce.nonces(address(this), wordPos));
    }

    function testInvalidateTwoNoncesRandomly(uint248 wordPos, uint256 startBitmap, uint256 mask) public {
        unorderedNonce.invalidateUnorderedNonces(wordPos, startBitmap);
        assertEq(startBitmap, unorderedNonce.nonces(address(this), wordPos));

        // invalidating with the mask changes the original bitmap
        uint256 finalBitmap = startBitmap | mask;
        unorderedNonce.invalidateUnorderedNonces(wordPos, mask);
        uint256 savedBitmap = unorderedNonce.nonces(address(this), wordPos);
        assertEq(finalBitmap, savedBitmap);

        // invalidating with the same mask should do nothing
        unorderedNonce.invalidateUnorderedNonces(wordPos, mask);
        assertEq(savedBitmap, unorderedNonce.nonces(address(this), wordPos));
    }
}
