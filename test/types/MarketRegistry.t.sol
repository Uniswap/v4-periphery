// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MarketParams} from "morpho-blue/interfaces/IMorpho.sol";

import {Market} from "../../src/types/Market.sol";
import {MarketRegistry, MarketNotSupported} from "../../src/types/MarketRegistry.sol";

contract MarketRegistryTest is Test {
    MarketRegistry internal registry;

    Currency internal collateral = Currency.wrap(address(0xC0));
    Currency internal debt = Currency.wrap(address(0xDB));

    function _mp(address coll, address loan, uint256 lltv) internal pure returns (MarketParams memory) {
        return MarketParams({
            loanToken: loan, collateralToken: coll, oracle: address(0x07AC1E), irm: address(0x12), lltv: lltv
        });
    }

    // external wrapper so vm.expectRevert catches the storage free-function revert at a call boundary
    function resolveExt(Market memory m) external view returns (uint256 lltv) {
        return registry.resolve(m).lltv;
    }

    function test_register_then_resolve() public {
        registry.register(_mp(Currency.unwrap(collateral), Currency.unwrap(debt), 0.86e18));
        Market memory m = Market({collateral: collateral, debt: debt});
        MarketParams memory got = registry.resolve(m);
        assertEq(got.lltv, 0.86e18);
        assertEq(got.collateralToken, Currency.unwrap(collateral));
        assertEq(got.loanToken, Currency.unwrap(debt));
        assertTrue(registry.isSupported(m));
    }

    function test_resolve_revertsMarketNotSupported_whenUnset() public {
        Market memory m = Market({collateral: collateral, debt: debt});
        assertFalse(registry.isSupported(m));
        vm.expectRevert(abi.encodeWithSelector(MarketNotSupported.selector, collateral, debt));
        this.resolveExt(m);
    }

    function testFuzz_register_resolve_roundTrips(address coll, address loan, uint256 lltv) public {
        vm.assume(coll != address(0) || loan != address(0));
        registry.register(_mp(coll, loan, lltv));
        Market memory m = Market({collateral: Currency.wrap(coll), debt: Currency.wrap(loan)});
        assertTrue(registry.isSupported(m));
        assertEq(registry.resolve(m).lltv, lltv);
    }

    function test_count_and_page_trackRegisteredPairs() public {
        assertEq(registry.count(), 0);
        registry.register(_mp(address(1), address(2), 0.8e18));
        registry.register(_mp(address(3), address(4), 0.7e18));
        assertEq(registry.count(), 2);

        Market[] memory all = registry.page(0, 10);
        assertEq(all.length, 2);
        assertEq(Currency.unwrap(all[0].collateral), address(1));
        assertEq(Currency.unwrap(all[1].collateral), address(3));
    }

    function test_reRegister_replacesParams_withoutDuplicatingKey() public {
        registry.register(_mp(address(1), address(2), 0.8e18));
        // replacing the same pair updates MarketParams but must not append a second key
        registry.register(_mp(address(1), address(2), 0.9e18));
        assertEq(registry.count(), 1);
        assertEq(
            registry.resolve(Market({collateral: Currency.wrap(address(1)), debt: Currency.wrap(address(2))})).lltv,
            0.9e18
        );
    }

    function test_register_allZeroPair_isNoOp_keepsEnumerationConsistent() public {
        registry.register(_mp(address(0), address(0), 0.8e18));
        // the all-zero pair reads as unregistered, so it must never appear in the enumerable set
        assertEq(registry.count(), 0);
        assertEq(registry.page(0, 10).length, 0);
        Market memory zero = Market({collateral: Currency.wrap(address(0)), debt: Currency.wrap(address(0))});
        assertFalse(registry.isSupported(zero));
    }

    function test_page_bounds() public {
        registry.register(_mp(address(1), address(2), 0.8e18));
        registry.register(_mp(address(3), address(4), 0.7e18));
        assertEq(registry.page(2, 10).length, 0);
        assertEq(registry.page(1, 10).length, 1);
        assertEq(registry.page(0, 1).length, 1);
        assertEq(registry.page(0, type(uint256).max).length, 2);
    }
}
