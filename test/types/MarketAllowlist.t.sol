// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {Market} from "../../src/types/Market.sol";
import {MarketAllowlist, MarketNotSupported} from "../../src/types/MarketAllowlist.sol";

contract MarketAllowlistTest is Test {
    MarketAllowlist internal allowlist;

    Currency internal collateral = Currency.wrap(address(0xC0));
    Currency internal debt = Currency.wrap(address(0xDB));

    // external wrapper so vm.expectRevert catches the storage free-function revert at a call boundary
    function requireAllowedExt(Market memory m) external view {
        allowlist.requireAllowed(m);
    }

    function test_set_then_isAllowed() public {
        Market memory m = Market({collateral: collateral, debt: debt});
        assertFalse(allowlist.isAllowed(m));
        allowlist.set(collateral, debt, true);
        assertTrue(allowlist.isAllowed(m));
        allowlist.requireAllowed(m); // does not revert
    }

    function test_set_false_disables() public {
        Market memory m = Market({collateral: collateral, debt: debt});
        allowlist.set(collateral, debt, true);
        allowlist.set(collateral, debt, false);
        assertFalse(allowlist.isAllowed(m));
        vm.expectRevert(abi.encodeWithSelector(MarketNotSupported.selector, collateral, debt));
        this.requireAllowedExt(m);
    }

    function test_requireAllowed_revertsWhenNotSet() public {
        Market memory m = Market({collateral: collateral, debt: debt});
        assertFalse(allowlist.isAllowed(m));
        vm.expectRevert(abi.encodeWithSelector(MarketNotSupported.selector, collateral, debt));
        this.requireAllowedExt(m);
    }

    function testFuzz_set_isAllowed_roundTrips(address coll, address loan, bool allowed) public {
        allowlist.set(Currency.wrap(coll), Currency.wrap(loan), allowed);
        Market memory m = Market({collateral: Currency.wrap(coll), debt: Currency.wrap(loan)});
        assertEq(allowlist.isAllowed(m), allowed);
    }

    function _mkt(uint160 c, uint160 d) internal pure returns (Market memory) {
        return Market({collateral: Currency.wrap(address(c)), debt: Currency.wrap(address(d))});
    }

    function test_count_and_page_trackAllowedSet() public {
        assertEq(allowlist.count(), 0);
        allowlist.set(Currency.wrap(address(1)), Currency.wrap(address(2)), true);
        allowlist.set(Currency.wrap(address(3)), Currency.wrap(address(4)), true);
        assertEq(allowlist.count(), 2);

        Market[] memory all = allowlist.page(0, 10);
        assertEq(all.length, 2);
        assertEq(Currency.unwrap(all[0].collateral), address(1));
        assertEq(Currency.unwrap(all[1].collateral), address(3));
    }

    function test_set_idempotent_doesNotDuplicate() public {
        allowlist.set(Currency.wrap(address(1)), Currency.wrap(address(2)), true);
        allowlist.set(Currency.wrap(address(1)), Currency.wrap(address(2)), true);
        assertEq(allowlist.count(), 1);
        // disabling an already-absent pair is also a no-op
        allowlist.set(Currency.wrap(address(9)), Currency.wrap(address(9)), false);
        assertEq(allowlist.count(), 1);
    }

    function test_remove_swapPops_and_preservesOthers() public {
        allowlist.set(Currency.wrap(address(1)), Currency.wrap(address(2)), true);
        allowlist.set(Currency.wrap(address(3)), Currency.wrap(address(4)), true);
        allowlist.set(Currency.wrap(address(5)), Currency.wrap(address(6)), true);
        // remove the middle entry: the last entry swaps into its slot
        allowlist.set(Currency.wrap(address(3)), Currency.wrap(address(4)), false);

        assertEq(allowlist.count(), 2);
        assertFalse(allowlist.isAllowed(_mkt(3, 4)));
        assertTrue(allowlist.isAllowed(_mkt(1, 2)));
        assertTrue(allowlist.isAllowed(_mkt(5, 6)));

        Market[] memory all = allowlist.page(0, 10);
        assertEq(all.length, 2);
        assertEq(Currency.unwrap(all[0].collateral), address(1));
        assertEq(Currency.unwrap(all[1].collateral), address(5));

        // re-enabling appends again with a fresh index
        allowlist.set(Currency.wrap(address(3)), Currency.wrap(address(4)), true);
        assertEq(allowlist.count(), 3);
        assertTrue(allowlist.isAllowed(_mkt(3, 4)));
    }

    function test_page_bounds() public {
        allowlist.set(Currency.wrap(address(1)), Currency.wrap(address(2)), true);
        allowlist.set(Currency.wrap(address(3)), Currency.wrap(address(4)), true);
        // offset at or beyond length -> empty
        assertEq(allowlist.page(2, 10).length, 0);
        assertEq(allowlist.page(5, 10).length, 0);
        // tail clamped to what remains
        Market[] memory p = allowlist.page(1, 10);
        assertEq(p.length, 1);
        assertEq(Currency.unwrap(p[0].collateral), address(3));
        // limit smaller than remaining
        assertEq(allowlist.page(0, 1).length, 1);
        // max limit does not overflow
        assertEq(allowlist.page(0, type(uint256).max).length, 2);
    }
}
