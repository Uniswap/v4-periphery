// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SVG} from "../../src/libraries/SVG.sol";
import {Test} from "forge-std/Test.sol";

contract DescriptorTest is Test {
    function test_rangeLocation_succeeds() public pure {
        (string memory x, string memory y) = SVG.rangeLocation(-887_272, -887_100);
        assertEq(x, "8");
        assertEq(y, "7");
        (x, y) = SVG.rangeLocation(-100_000, -90_000);
        assertEq(x, "8");
        assertEq(y, "10.5");
        (x, y) = SVG.rangeLocation(-50_000, -20_000);
        assertEq(x, "8");
        assertEq(y, "14.25");
        (x, y) = SVG.rangeLocation(-10_000, -5_000);
        assertEq(x, "10");
        assertEq(y, "18");
        (x, y) = SVG.rangeLocation(-5_000, -4_000);
        assertEq(x, "11");
        assertEq(y, "21");
        (x, y) = SVG.rangeLocation(4_000, 5_000);
        assertEq(x, "13");
        assertEq(y, "23");
        (x, y) = SVG.rangeLocation(10_000, 15_000);
        assertEq(x, "15");
        assertEq(y, "25");
        (x, y) = SVG.rangeLocation(25_000, 50_000);
        assertEq(x, "18");
        assertEq(y, "26");
        (x, y) = SVG.rangeLocation(100_000, 125_000);
        assertEq(x, "21");
        assertEq(y, "27");
        (x, y) = SVG.rangeLocation(200_000, 100_000);
        assertEq(x, "24");
        assertEq(y, "27");
        (x, y) = SVG.rangeLocation(887_272, 887_272);
        assertEq(x, "24");
        assertEq(y, "27");
    }

    function test_isRare_succeeds() public pure {
        bool result = SVG.isRare(1, 0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB);
        assertTrue(result);
        result = SVG.isRare(2, 0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB);
        assertFalse(result);
    }

    function test_substring_succeeds() public pure {
        string memory result = SVG.substring("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", 0, 5);
        assertEq(result, "0xC02");
        result = SVG.substring("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", 39, 42);
        assertEq(result, "Cc2");
    }
}
