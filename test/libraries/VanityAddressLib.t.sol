// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VanityAddressLib} from "../../src/libraries/VanityAddressLib.sol";

contract VanityAddressLibTest is Test {
    function test_fuzz_reasonableScoreNeverReverts(address test) public pure {
        uint256 score = VanityAddressLib.score(address(test));
        assertGe(score, 0);
        assertLe(score, 444);
    }

    function test_scoreAllFours() public pure {
        address addr = address(0x4444444444444444444444444444444444444444);
        uint256 score = VanityAddressLib.score(addr);
        uint256 expected = 100; // 40 + 40 + 20 = 100
        assertEq(score, expected);
    }

    function test_scoreLaterFours() public pure {
        address addr = address(0x1444444444444444444444444444444444444444);
        uint256 score = VanityAddressLib.score(addr);
        uint256 expected = 0; // no leading 4
        assertEq(score, expected);
    }

    function test_scoreMixed_4() public pure {
        address addr = address(0x0044001111111111111111111111111111114114);
        // counts first null byte
        // counts first leading 4s after that
        // does not count future null bytes
        // counts 4 nibbles after that
        uint256 score = VanityAddressLib.score(addr);
        uint256 expected = 24; // 10 * 2 + 2 + 2 = 24
        assertEq(score, expected);
    }

    function test_scoreMixed_44() public pure {
        address addr = address(0x0044001111111111111111111111111111114444);
        // counts first null byte
        // counts first leading 4s after that
        // does not count future null bytes
        // counts 4 nibbles after that
        uint256 score = VanityAddressLib.score(addr);
        uint256 expected = 46; // 10 * 2 + 6 + 20 = 46
        assertEq(score, expected);
    }

    function test_scoreMixed_halfZeroHalf4() public pure {
        address addr = address(0x0004111111111111111111111111111111111111);
        // counts first null byte
        // counts first leading 4s after that
        uint256 score = VanityAddressLib.score(addr);
        uint256 expected = 31; // 10 * 3 + 1 = 31
        assertEq(score, expected);
    }

    function test_scores_succeed() public pure {
        assertEq(VanityAddressLib.score(address(0x0000000000000000000000000000000000000082)), 0); // 0
        assertEq(VanityAddressLib.score(address(0x0400000000000000000000000000000000000000)), 11); // 10 * 1 + 1 = 11
        assertEq(VanityAddressLib.score(address(0x0044000000000000000000000000000000004444)), 46); // 10 * 2 + 6 + 20 = 46
        assertEq(VanityAddressLib.score(address(0x4444000000000000000000000000000000004444)), 88); // 40 + 20 + 20 + 8 = 88
        assertEq(VanityAddressLib.score(address(0x0044440000000000000000000000000000000044)), 86); // 10 * 2 + 40 + 20 + 6 = 86
        assertEq(VanityAddressLib.score(address(0x0000444400000000000000000000000000004444)), 128); // 10 * 4 + 40 + 20 + 20 + 8 = 128
        assertEq(VanityAddressLib.score(address(0x0040444444444444444444444444444444444444)), 77); // 10 * 2 + 37 + 20 = 77
        assertEq(VanityAddressLib.score(address(0x0000000000000000000000000000000000000444)), 373); // 10 * 37 + 3 = 373
        assertEq(VanityAddressLib.score(address(0x0000000000000000000000000000000044444444)), 388); // 10 * 32 + 40 + 20 + 8 = 388
        assertEq(VanityAddressLib.score(address(0x0000000000000000000000000000000000454444)), 365); // 10 * 34 + 20 + 5 = 365
        assertEq(VanityAddressLib.score(address(0x0000000000000000000000000000000000000044)), 382); // 10 * 38 + 2 = 382
        assertEq(VanityAddressLib.score(address(0x0000000000000000000000000000000000000004)), 391); // 10 * 39 + 1 = 391
        assertEq(VanityAddressLib.score(address(0x0000000000000000000000000000000000444444)), 406); // 10 * 34 + 40 + 20 + 6 = 406
        assertEq(VanityAddressLib.score(address(0x0000000000000000000000000000000000044444)), 415); // 10 * 35 + 40 + 20 + 5 = 415
        assertEq(VanityAddressLib.score(address(0x0000000000000000000000000000000000444455)), 404); // 10 * 34 + 40 + 20 + 4 = 404
        assertEq(VanityAddressLib.score(address(0x0000000000000000000000000000000000044445)), 414); // 10 * 35 + 40 + 20 + 4 = 414
        assertEq(VanityAddressLib.score(address(0x0000000000000000000000000000000000004444)), 444); // 10 * 36 + 40 + 20 + 20 + 4 = 444
    }

    function test_betterThan() public pure {
        address addr1 = address(0x0011111111111111111111111111111111111111); // 0 points
        address addr2 = address(0x4000111111111111111111111111111111111111); // 1 points
        address addr3 = address(0x0000411111111111111111111111111111111111); // 10 * 4 + 1 = 41 points
        address addr4 = address(0x0000441111111111111111111111111111111111); // 10 * 4 + 2 = 42 points
        address addr5 = address(0x0000440011111111111111111111111111111111); // 10 * 4 + 2 = 42 points
        assertTrue(VanityAddressLib.betterThan(addr2, addr1)); // 1 > 0
        assertTrue(VanityAddressLib.betterThan(addr3, addr2)); // 41 > 1
        assertTrue(VanityAddressLib.betterThan(addr3, addr1)); // 41 > 0
        assertTrue(VanityAddressLib.betterThan(addr4, addr3)); // 42 > 41
        assertTrue(VanityAddressLib.betterThan(addr4, addr2)); // 42 > 1
        assertTrue(VanityAddressLib.betterThan(addr4, addr1)); // 42 > 0
        assertFalse(VanityAddressLib.betterThan(addr5, addr4)); // 42 == 42
        assertEq(VanityAddressLib.score(addr5), VanityAddressLib.score(addr4)); // 42 == 42
        assertTrue(VanityAddressLib.betterThan(addr5, addr3)); // 42 > 41
        assertTrue(VanityAddressLib.betterThan(addr5, addr2)); // 42 > 1
        assertTrue(VanityAddressLib.betterThan(addr5, addr1)); // 42 > 0

        address addr6 = address(0x0000000000000000000000000000000000004444);
        address addr7 = address(0x0000000000000000000000000000000000000082);
        assertTrue(VanityAddressLib.betterThan(addr6, addr7)); // 10 * 36 + 40 + 20 + 20 + 4 = 444 > 0
    }
}
