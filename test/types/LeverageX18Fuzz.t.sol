// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {LeverageX18, toLeverageX18, LeverageBelowOne, ONE_X18} from "../../src/types/LeverageX18.sol";

/// @notice Fuzz tests for the LeverageX18 value type — construction bounds,
///         mulEquity formula correctness and floor-rounding, and overflow guards.
contract LeverageX18FuzzTest is Test {
    // Maximum equity that can be passed to mulEquity without overflowing the intermediate
    // product `equity * x18` at 1x leverage: type(uint256).max / 1e18.
    uint256 internal constant MAX_SAFE_EQUITY = type(uint256).max / ONE_X18;

    // External wrapper so vm.expectRevert captures the free-function revert at a call boundary.
    function toLeverageX18Ext(uint256 x18) external pure returns (uint256) {
        return toLeverageX18(x18).raw();
    }

    // -------------------------------------------------------------------------
    // Construction
    // -------------------------------------------------------------------------

    /// toLeverageX18 accepts exactly x18 >= 1e18 and reverts below that.
    function testFuzz_toLeverageX18_revertsBelowOne(uint256 x18) public {
        x18 = bound(x18, 0, ONE_X18 - 1);
        vm.expectRevert(abi.encodeWithSelector(LeverageBelowOne.selector, x18));
        this.toLeverageX18Ext(x18);
    }

    /// toLeverageX18 round-trips: raw(toLeverageX18(x18)) == x18 for all valid inputs.
    function testFuzz_toLeverageX18_roundTrip(uint256 x18) public pure {
        x18 = bound(x18, ONE_X18, type(uint256).max);
        assertEq(toLeverageX18(x18).raw(), x18);
    }

    /// At the exact boundary 1e18 construction succeeds.
    function testFuzz_toLeverageX18_atBoundary_1x(uint256 delta) public pure {
        // delta == 0 => exactly 1x; delta > 0 => above 1x
        delta = bound(delta, 0, type(uint256).max - ONE_X18);
        uint256 x18 = ONE_X18 + delta;
        assertEq(toLeverageX18(x18).raw(), x18);
    }

    // -------------------------------------------------------------------------
    // mulEquity formula and rounding
    // -------------------------------------------------------------------------

    /// mulEquity(equity) == equity * self / 1e18, floored (integer division).
    function testFuzz_mulEquity_matchesFormula(uint128 equity, uint256 x18) public pure {
        // cap leverage to avoid phantom overflow in the reference formula: equity * x18 must fit
        // uint256. equity is uint128 (max ~3.4e38); x18 <= 2^128 keeps the product in uint256.
        x18 = bound(x18, ONE_X18, type(uint128).max);
        LeverageX18 lev = toLeverageX18(x18);
        uint256 expected = (uint256(equity) * x18) / ONE_X18;
        assertEq(lev.mulEquity(equity), expected);
    }

    /// mulEquity floors: result * 1e18 <= equity * leverage.
    function testFuzz_mulEquity_floorRounds(uint128 equity, uint256 x18) public pure {
        x18 = bound(x18, ONE_X18, type(uint128).max);
        LeverageX18 lev = toLeverageX18(x18);
        uint256 result = lev.mulEquity(equity);
        // floor means result * ONE_X18 <= equity * x18
        assertLe(result * ONE_X18, uint256(equity) * x18);
    }

    /// mulEquity at 1x leverage is identity: equity * 1e18 / 1e18 == equity.
    /// equity is bounded to MAX_SAFE_EQUITY so the intermediate product does not overflow.
    function testFuzz_mulEquity_atOneX_isIdentity(uint256 equity) public pure {
        equity = bound(equity, 0, MAX_SAFE_EQUITY);
        LeverageX18 oneX = toLeverageX18(ONE_X18);
        assertEq(oneX.mulEquity(equity), equity);
    }

    /// mulEquity with equity == 0 is always 0, regardless of leverage.
    function testFuzz_mulEquity_zeroEquity(uint256 x18) public pure {
        x18 = bound(x18, ONE_X18, type(uint128).max);
        assertEq(toLeverageX18(x18).mulEquity(0), 0);
    }
}
