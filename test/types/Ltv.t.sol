// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Ltv, toLtv} from "../../src/types/Ltv.sol";

contract LtvTest is Test {
    function test_wrap_roundTrip() public pure {
        assertEq(Ltv.unwrap(toLtv(0.86e18)), 0.86e18);
    }

    function test_gt() public pure {
        Ltv low = toLtv(0.5e18);
        Ltv high = toLtv(0.86e18);
        assertTrue(high.gt(low));
        assertFalse(low.gt(high));
        assertFalse(low.gt(low));
    }

    function testFuzz_compare(uint256 x, uint256 y) public pure {
        assertEq(toLtv(x).gt(toLtv(y)), x > y);
    }
}
