// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {Market, MarketSwapMismatch} from "../../src/types/Market.sol";

/// @notice Fuzz tests for the Market struct — hasCurrencies symmetry,
///         toSwapParams revert conditions, and zeroForOne derivation.
contract MarketFuzzTest is Test {
    // External wrapper so vm.expectRevert captures the free-function revert at a call boundary.
    function toSwapParamsExt(Market memory m, Currency input, int256 amount, PoolKey memory key)
        external
        pure
        returns (bool zeroForOne)
    {
        return m.toSwapParams(input, amount, 0, key).zeroForOne;
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _poolKey(Currency a, Currency b) internal pure returns (PoolKey memory) {
        return PoolKey({currency0: a, currency1: b, fee: 3000, tickSpacing: 60, hooks: IHooks(address(0))});
    }

    // Build a valid market + pool pair with two distinct tokens. Ensures currency0 < currency1
    // to satisfy pool canonical ordering — we just pick collateral as the "lower" one.
    function _validSetup(address rawColl, address rawDebt)
        internal
        pure
        returns (Market memory market, PoolKey memory key)
    {
        Currency coll = Currency.wrap(rawColl);
        Currency debt = Currency.wrap(rawDebt);
        // pool canonical ordering: currency0 < currency1 (by address)
        Currency c0 = rawColl < rawDebt ? coll : debt;
        Currency c1 = rawColl < rawDebt ? debt : coll;
        market = Market({collateral: coll, debt: debt});
        key = _poolKey(c0, c1);
    }

    // -------------------------------------------------------------------------
    // hasCurrencies symmetry
    // -------------------------------------------------------------------------

    /// hasCurrencies({a,b}) == hasCurrencies({b,a}) for any fuzzed market.
    function testFuzz_hasCurrencies_isSymmetric(address coll, address debt, address a, address b) public pure {
        Market memory m = Market({collateral: Currency.wrap(coll), debt: Currency.wrap(debt)});
        assertEq(
            m.hasCurrencies(Currency.wrap(a), Currency.wrap(b)), m.hasCurrencies(Currency.wrap(b), Currency.wrap(a))
        );
    }

    /// hasCurrencies returns true exactly when {a,b} == {collateral, debt} (as a set).
    function testFuzz_hasCurrencies_trueIffMatchesMarketSet(address coll, address debt, address a, address b)
        public
        pure
    {
        Market memory m = Market({collateral: Currency.wrap(coll), debt: Currency.wrap(debt)});
        bool expected = (a == coll && b == debt) || (a == debt && b == coll);
        assertEq(m.hasCurrencies(Currency.wrap(a), Currency.wrap(b)), expected);
    }

    // -------------------------------------------------------------------------
    // toSwapParams revert conditions
    // -------------------------------------------------------------------------

    /// toSwapParams reverts MarketSwapMismatch when pool currencies don't match the market.
    function testFuzz_toSwapParams_revertsWhenPoolMismatch(
        address collAddr,
        address debtAddr,
        address otherAddr,
        int256 amount
    ) public {
        vm.assume(collAddr != debtAddr);
        vm.assume(otherAddr != collAddr && otherAddr != debtAddr);
        vm.assume(amount != 0);

        Market memory m = Market({collateral: Currency.wrap(collAddr), debt: Currency.wrap(debtAddr)});
        // pool with one wrong currency
        PoolKey memory badKey = _poolKey(Currency.wrap(collAddr), Currency.wrap(otherAddr));

        vm.expectRevert(MarketSwapMismatch.selector);
        this.toSwapParamsExt(m, Currency.wrap(collAddr), amount, badKey);
    }

    /// toSwapParams reverts MarketSwapMismatch when input currency is not in the market.
    function testFuzz_toSwapParams_revertsWhenInputNotInMarket(
        address collAddr,
        address debtAddr,
        address otherAddr,
        int256 amount
    ) public {
        vm.assume(collAddr != debtAddr);
        vm.assume(otherAddr != collAddr && otherAddr != debtAddr);
        vm.assume(amount != 0);
        vm.assume(collAddr < debtAddr); // ensure canonical pool ordering

        Market memory m = Market({collateral: Currency.wrap(collAddr), debt: Currency.wrap(debtAddr)});
        PoolKey memory key = _poolKey(Currency.wrap(collAddr), Currency.wrap(debtAddr));

        vm.expectRevert(MarketSwapMismatch.selector);
        this.toSwapParamsExt(m, Currency.wrap(otherAddr), amount, key);
    }

    // -------------------------------------------------------------------------
    // toSwapParams zeroForOne derivation
    // -------------------------------------------------------------------------

    /// Selling currency0 into the pool => zeroForOne == true.
    function testFuzz_toSwapParams_sellingCurrency0_isZeroForOne(address rawLower, address rawHigher, int256 amount)
        public
    {
        vm.assume(rawLower < rawHigher); // canonical pool ordering
        vm.assume(amount != 0);

        Currency c0 = Currency.wrap(rawLower);
        Currency c1 = Currency.wrap(rawHigher);
        // market where c0 is the input (can be collateral or debt)
        Market memory m = Market({collateral: c1, debt: c0}); // sell c0 = debt
        PoolKey memory key = _poolKey(c0, c1);

        bool zeroForOne = this.toSwapParamsExt(m, c0, amount, key);
        assertTrue(zeroForOne, "selling c0 must be zeroForOne");
    }

    /// Selling currency1 into the pool => zeroForOne == false.
    function testFuzz_toSwapParams_sellingCurrency1_isNotZeroForOne(address rawLower, address rawHigher, int256 amount)
        public
    {
        vm.assume(rawLower < rawHigher); // canonical pool ordering
        vm.assume(amount != 0);

        Currency c0 = Currency.wrap(rawLower);
        Currency c1 = Currency.wrap(rawHigher);
        // market where c1 is the input
        Market memory m = Market({collateral: c0, debt: c1}); // sell c1 = debt
        PoolKey memory key = _poolKey(c0, c1);

        bool zeroForOne = this.toSwapParamsExt(m, c1, amount, key);
        assertFalse(zeroForOne, "selling c1 must not be zeroForOne");
    }

    /// amountSpecified is forwarded verbatim through toSwapParams.
    function testFuzz_toSwapParams_amountForwarded(address rawLower, address rawHigher, int256 amount) public pure {
        vm.assume(rawLower < rawHigher);
        vm.assume(amount != 0);

        Currency c0 = Currency.wrap(rawLower);
        Currency c1 = Currency.wrap(rawHigher);
        Market memory m = Market({collateral: c1, debt: c0});
        PoolKey memory key = _poolKey(c0, c1);

        SwapParams memory params = m.toSwapParams(c0, amount, 0, key);
        assertEq(params.amountSpecified, amount);
    }

    // -------------------------------------------------------------------------
    // eq
    // -------------------------------------------------------------------------

    /// eq is reflexive for any market.
    function testFuzz_eq_reflexive(address coll, address debt) public pure {
        Market memory m = Market({collateral: Currency.wrap(coll), debt: Currency.wrap(debt)});
        assertTrue(m.eq(m));
    }

    /// eq distinguishes markets that differ in collateral or debt.
    function testFuzz_eq_distinguishesDifferentMarkets(address coll, address debt) public pure {
        vm.assume(coll != debt);
        Market memory m = Market({collateral: Currency.wrap(coll), debt: Currency.wrap(debt)});
        Market memory flipped = Market({collateral: Currency.wrap(debt), debt: Currency.wrap(coll)});
        assertFalse(m.eq(flipped));
    }
}
