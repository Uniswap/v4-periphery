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
}
