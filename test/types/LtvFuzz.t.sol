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

    /// unwrap(toLtv(x)) == x for all x.
    function testFuzz_wrapRoundTrip(uint256 x) public pure {
        assertEq(Ltv.unwrap(toLtv(x)), x);
    }

    // -------------------------------------------------------------------------
    // Total-order consistency with uint comparison
    // -------------------------------------------------------------------------

    /// gt is consistent with the underlying uint comparison.
    function testFuzz_gt_matchesUintGt(uint256 x, uint256 y) public pure {
        assertEq(toLtv(x).gt(toLtv(y)), x > y);
    }

    /// Irreflexivity: a value is never gt itself.
    function testFuzz_gt_irreflexive(uint256 x) public pure {
        assertFalse(toLtv(x).gt(toLtv(x)));
    }

    /// Antisymmetry: if a > b then b is not > a.
    function testFuzz_gt_antisymmetric(uint256 x, uint256 y) public pure {
        if (x > y) assertFalse(toLtv(y).gt(toLtv(x)));
    }

    // -------------------------------------------------------------------------
    // Sentinel: type(uint256).max
    // -------------------------------------------------------------------------

    /// The max sentinel is gt any non-max value and never gt itself.
    function testFuzz_maxSentinel_gtAnyLesser(uint256 x) public pure {
        x = bound(x, 0, type(uint256).max - 1);
        assertTrue(toLtv(type(uint256).max).gt(toLtv(x)));
        assertFalse(toLtv(type(uint256).max).gt(toLtv(type(uint256).max)));
    }
}
