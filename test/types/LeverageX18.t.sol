// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {LeverageX18, toLeverageX18, LeverageBelowOne, ONE_X18} from "../../src/types/LeverageX18.sol";

contract LeverageX18Test is Test {
    // external wrapper so vm.expectRevert catches the free-function revert at a call boundary
    function toLeverageX18Ext(uint256 x18) external pure returns (uint256) {
        return toLeverageX18(x18).raw();
    }

    function test_toLeverageX18_acceptsOne() public pure {
        assertEq(toLeverageX18(ONE_X18).raw(), ONE_X18);
    }

    function test_toLeverageX18_revertsBelowOne_atBoundary() public {
        vm.expectRevert(abi.encodeWithSelector(LeverageBelowOne.selector, ONE_X18 - 1));
        this.toLeverageX18Ext(ONE_X18 - 1);
    }

    function test_mulEquity_threeX() public pure {
        assertEq(toLeverageX18(3e18).mulEquity(1 ether), 3 ether);
    }

    function testFuzz_toLeverageX18_roundTrips(uint256 x18) public pure {
        x18 = bound(x18, ONE_X18, type(uint256).max);
        assertEq(toLeverageX18(x18).raw(), x18);
    }

    function testFuzz_toLeverageX18_revertsBelowOne(uint256 x18) public {
        x18 = bound(x18, 0, ONE_X18 - 1);
        vm.expectRevert(abi.encodeWithSelector(LeverageBelowOne.selector, x18));
        this.toLeverageX18Ext(x18);
    }

    function testFuzz_mulEquity(uint256 x18, uint128 equity) public pure {
        x18 = bound(x18, ONE_X18, 1_000e18);
        assertEq(toLeverageX18(x18).mulEquity(equity), (uint256(equity) * x18) / ONE_X18);
    }
}
