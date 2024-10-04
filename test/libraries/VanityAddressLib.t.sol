// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {VanityAddressLib} from "../../src/libraries/VanityAddressLib.sol";

contract VanityAddressLibTest is Test {
    function test_scoreAllZeros() public pure {
        address addr = address(0);
        uint256 score = VanityAddressLib.score(addr);
        uint256 expected = 400; // 20 * 10
        assertEq(score, expected);
    }

    function test_scoreAllFours() public pure {
        address addr = address(0x4444444444444444444444444444444444444444);
        uint256 score = VanityAddressLib.score(addr);
        uint256 expected = 100; // 20 * 5
        assertEq(score, expected);
    }

    function test_scoreLaterFours() public pure {
        address addr = address(0x1444444444444444444444444444444444444444);
        uint256 score = VanityAddressLib.score(addr);
        uint256 expected = 39; // 1 + (5 * 19) = 39
        assertEq(score, expected);
    }

    function test_scoreMixed_4() public pure {
        address addr = address(0x0044001111111111111111111111111111114114);
        // counts first null byte
        // counts first leading 4s after that
        // does not count future null bytes
        // counts 4 nibbles after that
        uint256 score = VanityAddressLib.score(addr);
        uint256 expected = 27; // 20+5+1+1
        assertEq(score, expected);
    }

    function test_scoreMixed_44() public pure {
        address addr = address(0x0044001111111111111111111111111111114444);
        // counts first null byte
        // counts first leading 4s after that
        // does not count future null bytes
        // counts 4 nibbles after that
        uint256 score = VanityAddressLib.score(addr);
        uint256 expected = 29; // 20+5+2+2
        assertEq(score, expected);
    }

    function test_betterThan() public pure {
        address addr1 = address(0x0011111111111111111111111111111111111111); // 20 points
        address addr2 = address(0x0000111111111111111111111111111111111111); // 40 points
        address addr3 = address(0x0000411111111111111111111111111111111111); // 41 points
        address addr4 = address(0x0000441111111111111111111111111111111111); // 45 points
        address addr5 = address(0x0000440011111111111111111111111111111111); // 45 points
        assertTrue(VanityAddressLib.betterThan(addr2, addr1)); // 40 > 20
        assertTrue(VanityAddressLib.betterThan(addr3, addr2)); // 41 > 40
        assertTrue(VanityAddressLib.betterThan(addr3, addr1)); // 41 > 20
        assertTrue(VanityAddressLib.betterThan(addr4, addr3)); // 45 > 41
        assertTrue(VanityAddressLib.betterThan(addr4, addr2)); // 45 > 40
        assertTrue(VanityAddressLib.betterThan(addr4, addr1)); // 45 > 20
        assertFalse(VanityAddressLib.betterThan(addr5, addr4)); // 45 == 45
        assertEq(VanityAddressLib.score(addr5), VanityAddressLib.score(addr4)); // 45 == 45
        assertTrue(VanityAddressLib.betterThan(addr5, addr3)); // 45 > 41
        assertTrue(VanityAddressLib.betterThan(addr5, addr2)); // 45 > 40
        assertTrue(VanityAddressLib.betterThan(addr5, addr1)); // 45 > 20

        // is this intentional?
        address addr6 = address(0x0000000000000000000000000000000000044444);
        address addr7 = address(0x0000000000000000000000000000000000000082);
        assertFalse(VanityAddressLib.betterThan(addr6, addr7)); // 20 * 18 + 5 + 5 = 370 < 20 * 19 = 380
    }
}
