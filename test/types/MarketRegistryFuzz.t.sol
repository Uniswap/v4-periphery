// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MarketParams} from "morpho-blue/interfaces/IMorpho.sol";

import {Market} from "../../src/types/Market.sol";
import {MarketRegistry, MarketNotSupported} from "../../src/types/MarketRegistry.sol";

/// @notice Fuzz tests for the MarketRegistry storage type — register/resolve
///         round-trips and unregistered-pair revert behaviour.
contract MarketRegistryFuzzTest is Test {
    MarketRegistry internal registry;

    // External wrapper so vm.expectRevert captures the storage free-function revert at a call boundary.
    function resolveExt(Market memory m) external view returns (address collateralToken, address loanToken) {
        MarketParams memory mp = registry.resolve(m);
        collateralToken = mp.collateralToken;
        loanToken = mp.loanToken;
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _mp(address coll, address loan, uint256 lltv) internal pure returns (MarketParams memory) {
        return MarketParams({
            loanToken: loan, collateralToken: coll, oracle: address(0x07AC1E), irm: address(0x12), lltv: lltv
        });
    }

    // -------------------------------------------------------------------------
    // register / resolve round-trips
    // -------------------------------------------------------------------------

    /// register then resolve returns the stored MarketParams.
    function testFuzz_register_resolve_roundTrip(address coll, address loan, uint256 lltv) public {
        // The registry uses address(0) for both fields as the "not found" sentinel.
        vm.assume(coll != address(0) || loan != address(0));

        MarketParams memory mp = _mp(coll, loan, lltv);
        registry.register(mp);

        Market memory m = Market({collateral: Currency.wrap(coll), debt: Currency.wrap(loan)});

        assertTrue(registry.isSupported(m), "isSupported after register");
        MarketParams memory got = registry.resolve(m);
        assertEq(got.collateralToken, coll, "collateralToken round-trip");
        assertEq(got.loanToken, loan, "loanToken round-trip");
        assertEq(got.lltv, lltv, "lltv round-trip");
    }

    /// Re-registering with updated lltv replaces the old entry.
    function testFuzz_register_replace_updatesLltv(address coll, address loan, uint256 lltv1, uint256 lltv2) public {
        vm.assume(coll != address(0) || loan != address(0));
        vm.assume(lltv1 != lltv2);

        registry.register(_mp(coll, loan, lltv1));
        registry.register(_mp(coll, loan, lltv2));

        Market memory m = Market({collateral: Currency.wrap(coll), debt: Currency.wrap(loan)});
        assertEq(registry.resolve(m).lltv, lltv2, "second register must override");
    }

    /// Two distinct pairs are stored and resolved independently.
    function testFuzz_register_twoDistinctPairs_independentSlots(
        address collA,
        address loanA,
        address collB,
        address loanB,
        uint256 lltvA,
        uint256 lltvB
    ) public {
        // Pairs must be distinct and non-zero sentinel.
        vm.assume(collA != address(0) || loanA != address(0));
        vm.assume(collB != address(0) || loanB != address(0));
        vm.assume(collA != collB || loanA != loanB);

        registry.register(_mp(collA, loanA, lltvA));
        registry.register(_mp(collB, loanB, lltvB));

        Market memory mA = Market({collateral: Currency.wrap(collA), debt: Currency.wrap(loanA)});
        Market memory mB = Market({collateral: Currency.wrap(collB), debt: Currency.wrap(loanB)});

        assertEq(registry.resolve(mA).lltv, lltvA, "pair A lltv");
        assertEq(registry.resolve(mB).lltv, lltvB, "pair B lltv");
    }

    // -------------------------------------------------------------------------
    // Unregistered pairs
    // -------------------------------------------------------------------------

    /// resolve reverts MarketNotSupported for any unregistered pair.
    function testFuzz_resolve_revertsForUnregistered(address coll, address loan) public {
        Market memory m = Market({collateral: Currency.wrap(coll), debt: Currency.wrap(loan)});
        assertFalse(registry.isSupported(m), "fresh registry must not support");
        vm.expectRevert(abi.encodeWithSelector(MarketNotSupported.selector, Currency.wrap(coll), Currency.wrap(loan)));
        this.resolveExt(m);
    }

    /// isSupported returns false for unregistered pairs regardless of content.
    function testFuzz_isSupported_falseWhenUnregistered(address coll, address loan) public view {
        Market memory m = Market({collateral: Currency.wrap(coll), debt: Currency.wrap(loan)});
        assertFalse(registry.isSupported(m));
    }

    /// Registering pair (A,B) does not make the reversed pair (B,A) supported.
    function testFuzz_register_doesNotRegisterReverse(address coll, address loan, uint256 lltv) public {
        vm.assume(coll != loan);
        vm.assume(coll != address(0) || loan != address(0));

        registry.register(_mp(coll, loan, lltv));

        Market memory m = Market({collateral: Currency.wrap(loan), debt: Currency.wrap(coll)});
        assertFalse(registry.isSupported(m), "reverse pair must remain unsupported");
    }

    /// register then isSupported matches registered pair precisely.
    function testFuzz_isSupported_trueAfterRegister(address coll, address loan, uint256 lltv) public {
        vm.assume(coll != address(0) || loan != address(0));

        registry.register(_mp(coll, loan, lltv));
        Market memory m = Market({collateral: Currency.wrap(coll), debt: Currency.wrap(loan)});
        assertTrue(registry.isSupported(m));
    }
}
