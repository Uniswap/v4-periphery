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
        uint256 expected = 120; // 6 * 20
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
        uint256 expected = 28; // 20+6+1+1
        assertEq(score, expected);
    }

    function test_scoreMixed_44() public pure {
        address addr = address(0x0044001111111111111111111111111111114444);
        // counts first null byte
        // counts first leading 4s after that
        // does not count future null bytes
        // counts 4 nibbles after that
        uint256 score = VanityAddressLib.score(addr);
        uint256 expected = 30; // 20+6+2+2
        assertEq(score, expected);
    }

    function test_scoreMixed_halfZeroHalf4() public pure {
        address addr = address(0x0004111111111111111111111111111111111111);
        // counts first null byte
        // counts first leading 4s after that
        uint256 score = VanityAddressLib.score(addr);
        uint256 expected = 33; // 20+10+3
        assertEq(score, expected);
    }

    function test_betterThan() public pure {
        address addr1 = address(0x0011111111111111111111111111111111111111); // 20 points
        address addr2 = address(0x0000111111111111111111111111111111111111); // 40 points
        address addr3 = address(0x0000411111111111111111111111111111111111); // 43 points
        address addr4 = address(0x0000441111111111111111111111111111111111); // 46 points
        address addr5 = address(0x0000440011111111111111111111111111111111); // 46 points
        assertTrue(VanityAddressLib.betterThan(addr2, addr1)); // 40 > 20
        assertTrue(VanityAddressLib.betterThan(addr3, addr2)); // 43 > 40
        assertTrue(VanityAddressLib.betterThan(addr3, addr1)); // 43 > 20
        assertTrue(VanityAddressLib.betterThan(addr4, addr3)); // 46 > 43
        assertTrue(VanityAddressLib.betterThan(addr4, addr2)); // 46 > 40
        assertTrue(VanityAddressLib.betterThan(addr4, addr1)); // 46 > 20
        assertFalse(VanityAddressLib.betterThan(addr5, addr4)); // 46 == 46
        assertEq(VanityAddressLib.score(addr5), VanityAddressLib.score(addr4)); // 46 == 46
        assertTrue(VanityAddressLib.betterThan(addr5, addr3)); // 46 > 43
        assertTrue(VanityAddressLib.betterThan(addr5, addr2)); // 46 > 40
        assertTrue(VanityAddressLib.betterThan(addr5, addr1)); // 46 > 20

        // is this intentional?
        address addr6 = address(0x0000000000000000000000000000000000004444);
        address addr7 = address(0x0000000000000000000000000000000000000082);
        assertFalse(VanityAddressLib.betterThan(addr6, addr7)); // 20 * 18 + 6 + 6 = 372 < 20 * 19 = 380
    }
}
