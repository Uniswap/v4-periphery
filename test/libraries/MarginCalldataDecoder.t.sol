// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Actions} from "../../src/libraries/Actions.sol";

import {MarginActions} from "../../src/libraries/MarginActions.sol";
import {MarginCalldataDecoder} from "../../src/libraries/MarginCalldataDecoder.sol";
import {ILendingAdapter} from "../../src/interfaces/ILendingAdapter.sol";
import {Market} from "../../src/types/Market.sol";
import {Ltv, toLtv} from "../../src/types/Ltv.sol";

contract MarginCalldataDecoderTest is Test {
    Currency internal collateral = Currency.wrap(address(0xC0));
    Currency internal debt = Currency.wrap(address(0xDB));

    // external wrappers so the library's calldata decoders run on calldata
    function decAmount(bytes calldata p)
        external
        pure
        returns (address adapter, Currency c, Currency d, uint256 amount)
    {
        ILendingAdapter a;
        Market memory m;
        (a, m, amount) = MarginCalldataDecoder.decodeAdapterMarketAmount(p);
        return (address(a), m.collateral, m.debt, amount);
    }

    function decReceiver(bytes calldata p) external pure returns (address adapter, uint256 amount, address to) {
        ILendingAdapter a;
        Market memory m;
        (a, m, amount, to) = MarginCalldataDecoder.decodeAdapterMarketAmountReceiver(p);
        return (address(a), amount, to);
    }

    function decSweep(bytes calldata p) external pure returns (Currency c, uint256 amount, address to) {
        return MarginCalldataDecoder.decodeSweep(p);
    }

    function decHealth(bytes calldata p) external pure returns (address adapter, uint256 maxLtv) {
        ILendingAdapter a;
        Market memory m;
        Ltv lim;
        (a, m, lim) = MarginCalldataDecoder.decodeHealthCheck(p);
        return (address(a), Ltv.unwrap(lim));
    }

    function decSubId(bytes calldata p) external pure returns (uint256 subId) {
        return MarginCalldataDecoder.decodeSubId(p);
    }

    function decPull(bytes calldata p) external pure returns (Currency c, uint256 amount, bool payerIsUser) {
        return MarginCalldataDecoder.decodePull(p);
    }

    function test_decodeAdapterMarketAmount_roundTrips() public view {
        Market memory m = Market({collateral: collateral, debt: debt});
        bytes memory p = abi.encode(ILendingAdapter(address(0xAD)), m, 42e18);
        (address adapter, Currency c, Currency d, uint256 amount) = this.decAmount(p);
        assertEq(adapter, address(0xAD));
        assertTrue(c == collateral && d == debt);
        assertEq(amount, 42e18);
    }

    function test_decodeAdapterMarketAmountReceiver_roundTrips() public view {
        Market memory m = Market({collateral: collateral, debt: debt});
        bytes memory p = abi.encode(ILendingAdapter(address(0xAD)), m, 7e18, address(0xB0B));
        (address adapter, uint256 amount, address to) = this.decReceiver(p);
        assertEq(adapter, address(0xAD));
        assertEq(amount, 7e18);
        assertEq(to, address(0xB0B));
    }

    function test_decodeSweep_roundTrips() public view {
        bytes memory p = abi.encode(collateral, 3e18, address(0xB0B));
        (Currency c, uint256 amount, address to) = this.decSweep(p);
        assertTrue(c == collateral);
        assertEq(amount, 3e18);
        assertEq(to, address(0xB0B));
    }

    function test_decodeHealthCheck_roundTrips() public view {
        Market memory m = Market({collateral: collateral, debt: debt});
        bytes memory p = abi.encode(ILendingAdapter(address(0xAD)), m, toLtv(0.8e18));
        (address adapter, uint256 maxLtv) = this.decHealth(p);
        assertEq(adapter, address(0xAD));
        assertEq(maxLtv, 0.8e18);
    }

    function testFuzz_decodeAdapterMarketAmountReceiver(address adapter, uint256 amount, address to) public view {
        Market memory m = Market({collateral: collateral, debt: debt});
        bytes memory p = abi.encode(ILendingAdapter(adapter), m, amount, to);
        (address gotAdapter, uint256 gotAmount, address gotTo) = this.decReceiver(p);
        assertEq(gotAdapter, adapter);
        assertEq(gotAmount, amount);
        assertEq(gotTo, to);
    }

    function test_decodeSubId_roundTrips() public view {
        bytes memory p = abi.encode(uint256(7));
        assertEq(this.decSubId(p), 7);
    }

    function test_decodePull_roundTrips() public view {
        bytes memory p = abi.encode(collateral, 5e18, true);
        (Currency c, uint256 amount, bool payerIsUser) = this.decPull(p);
        assertTrue(c == collateral);
        assertEq(amount, 5e18);
        assertTrue(payerIsUser);
    }

    function testFuzz_decodeSubId(uint256 subId) public view {
        assertEq(this.decSubId(abi.encode(subId)), subId);
    }

    function testFuzz_decodePull(uint256 amount, bool payerIsUser) public view {
        bytes memory p = abi.encode(debt, amount, payerIsUser);
        (Currency c, uint256 gotAmount, bool gotPayerIsUser) = this.decPull(p);
        assertTrue(c == debt);
        assertEq(gotAmount, amount);
        assertEq(gotPayerIsUser, payerIsUser);
    }

    function test_opcodes_areContiguousAndDisjointFromActions() public pure {
        assertEq(MarginActions.ACCOUNT_SUPPLY_COLLATERAL, 0x30);
        assertEq(MarginActions.ACCOUNT_WITHDRAW_COLLATERAL, 0x31);
        assertEq(MarginActions.ACCOUNT_BORROW, 0x32);
        assertEq(MarginActions.ACCOUNT_REPAY, 0x33);
        assertEq(MarginActions.ACCOUNT_SWEEP, 0x34);
        assertEq(MarginActions.ASSERT_HEALTH, 0x35);
        assertEq(MarginActions.ASSERT_FILL, 0x36);
        assertEq(MarginActions.SET_ACCOUNT, 0x37);
        assertEq(MarginActions.PULL_TO_ACCOUNT, 0x38);
        // margin opcodes start at 0x30, leaving a reserved gap above the inherited Actions space
        // (which ends at 0x1b) for future core actions to grow into without colliding
        assertGe(MarginActions.ACCOUNT_SUPPLY_COLLATERAL, Actions.UNSUBSCRIBE + 4);
    }

    function test_sweepWrapUnwrap_areContiguous() public pure {
        // MarginRouter._handleAction gates the SWEEP/WRAP/UNWRAP interception as a single
        // `>= SWEEP && <= UNWRAP` range; this pins the contiguity that gate relies on against a
        // future Actions reordering.
        assertEq(Actions.SWEEP + 1, Actions.WRAP);
        assertEq(Actions.WRAP + 1, Actions.UNWRAP);
    }
}
