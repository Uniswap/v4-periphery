// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Ltv, toLtv} from "../../src/types/Ltv.sol";

/// @notice Fuzz tests for the Ltv value type — round-trip, comparison consistency,
///         and sentinel (type(uint256).max) edge cases.
contract LtvFuzzTest is Test {
    // -------------------------------------------------------------------------
    // Round-trip
    // -------------------------------------------------------------------------

    /// raw(toLtv(x)) == x for all x.
    function testFuzz_rawRoundTrip(uint256 x) public pure {
        assertEq(toLtv(x).raw(), x);
    }

    // -------------------------------------------------------------------------
    // Total-order consistency with uint comparison
    // -------------------------------------------------------------------------

    /// lte and gt are total and mutually exclusive.
    function testFuzz_lteAndGt_totalAndMutuallyExclusive(uint256 x, uint256 y) public pure {
        Ltv a = toLtv(x);
        Ltv b = toLtv(y);
        // exactly one of lte(x,y) and gt(x,y) must be true when they differ
        assertTrue(a.lte(b) || a.gt(b), "one must hold");
        // when equal both lte holds and gt does not
        if (x == y) {
            assertTrue(a.lte(b), "equal => lte");
            assertFalse(a.gt(b), "equal => not gt");
        }
    }

    /// lte is consistent with the underlying uint comparison.
    function testFuzz_lte_matchesUintLe(uint256 x, uint256 y) public pure {
        assertEq(toLtv(x).lte(toLtv(y)), x <= y);
    }

    /// gt is consistent with the underlying uint comparison.
    function testFuzz_gt_matchesUintGt(uint256 x, uint256 y) public pure {
        assertEq(toLtv(x).gt(toLtv(y)), x > y);
    }

    /// Antisymmetry: if a > b then b is not > a.
    function testFuzz_gt_antisymmetric(uint256 x, uint256 y) public pure {
        if (x > y) assertFalse(toLtv(y).gt(toLtv(x)));
    }

    // -------------------------------------------------------------------------
    // Sentinel: type(uint256).max
    // -------------------------------------------------------------------------

    /// The max sentinel is gt any non-max value.
    function testFuzz_maxSentinel_gtAnyLesser(uint256 x) public pure {
        x = bound(x, 0, type(uint256).max - 1);
        assertTrue(toLtv(type(uint256).max).gt(toLtv(x)));
    }

    /// The max sentinel is lte itself.
    function testFuzz_maxSentinel_lteItself() public pure {
        Ltv maxLtv = toLtv(type(uint256).max);
        assertTrue(maxLtv.lte(maxLtv));
        assertFalse(maxLtv.gt(maxLtv));
    }

    /// Any non-max value is lte the max sentinel.
    function testFuzz_anyLesser_lteMax(uint256 x) public pure {
        x = bound(x, 0, type(uint256).max - 1);
        assertTrue(toLtv(x).lte(toLtv(type(uint256).max)));
    }
}
