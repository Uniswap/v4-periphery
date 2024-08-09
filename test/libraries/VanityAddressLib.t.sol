// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {VanityAddressLib} from "../../contracts/libraries/VanityAddressLib.sol";

contract VanityAddressLibTest is Test {
    // function testScore(uint8 numZerosStart, uint8 numFoursStart, uint8 numOtherFours) public {
    function testScoreAllZeros() public {
        address addr = address(0);
        uint256 score = VanityAddressLib.score(addr);
        uint256 expected = 400; // 20 * 10
        assertEq(score, expected);
    }

    function testScoreAllFours() public {
        address addr = address(0x4444444444444444444444444444444444444444);
        uint256 score = VanityAddressLib.score(addr);
        uint256 expected = 100; // 20 * 5
        assertEq(score, expected);
    }

    function testScoreLaterFours() public {
        address addr = address(0x1444444444444444444444444444444444444444);
        uint256 score = VanityAddressLib.score(addr);
        uint256 expected = 39; // 20 + 19
        assertEq(score, expected);
    }

    function testScoreMixed() public {
        address addr = address(0x0044001111111111111111111111111111114114);
        // counts first null byte
        // counts first leading 4s after that
        // does not count future null bytes
        // counts 4 nibbles after that
        uint256 score = VanityAddressLib.score(addr);
        uint256 expected = 27; // 10+5+1+1
        assertEq(score, expected);
    }

    function testBetterThan() public {
        address addr1 = address(0x0011111111111111111111111111111111111111);
        address addr2 = address(0x0000111111111111111111111111111111111111);
        address addr3 = address(0x0000411111111111111111111111111111111111);
        address addr4 = address(0x0000441111111111111111111111111111111111);
        address addr5 = address(0x0000440011111111111111111111111111111111);
        assertTrue(VanityAddressLib.betterThan(addr2, addr1));
        assertTrue(VanityAddressLib.betterThan(addr3, addr2));
        assertTrue(VanityAddressLib.betterThan(addr3, addr1));
        assertTrue(VanityAddressLib.betterThan(addr4, addr3));
        assertTrue(VanityAddressLib.betterThan(addr4, addr2));
        assertTrue(VanityAddressLib.betterThan(addr4, addr1));
        assertFalse(VanityAddressLib.betterThan(addr5, addr4));
        assertEq(VanityAddressLib.score(addr5), VanityAddressLib.score(addr4));
        assertTrue(VanityAddressLib.betterThan(addr5, addr3));
        assertTrue(VanityAddressLib.betterThan(addr5, addr2));
        assertTrue(VanityAddressLib.betterThan(addr5, addr1));
    }
}
