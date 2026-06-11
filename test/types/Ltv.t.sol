// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Ltv, toLtv} from "../../src/types/Ltv.sol";

contract LtvTest is Test {
    function test_raw_roundTrip() public pure {
        assertEq(toLtv(0.86e18).raw(), 0.86e18);
    }

    function test_lte_and_gt() public pure {
        Ltv low = toLtv(0.5e18);
        Ltv high = toLtv(0.86e18);
        assertTrue(low.lte(high));
        assertTrue(low.lte(low));
        assertTrue(high.gt(low));
        assertFalse(high.lte(low));
        assertFalse(low.gt(high));
    }

    function testFuzz_compare(uint256 x, uint256 y) public pure {
        assertEq(toLtv(x).lte(toLtv(y)), x <= y);
        assertEq(toLtv(x).gt(toLtv(y)), x > y);
    }
}
