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
            loanToken: loan,
            collateralToken: coll,
            oracle: address(0x07AC1E),
            irm: address(0x12),
            lltv: lltv
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
}
