// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {CompoundV3LendingAdapter} from "../../src/CompoundV3LendingAdapter.sol";
import {IComet} from "../../src/interfaces/external/compound-v3/IComet.sol";
import {Market} from "../../src/types/Market.sol";
import {NotOwner, ZeroOwner} from "../../src/types/Owner.sol";
import {Ltv, raw} from "../../src/types/Ltv.sol";
import {PositionData} from "../../src/types/PositionData.sol";
import {MockComet} from "../mocks/MockComet.sol";

contract CompoundV3LendingAdapterTest is Test {
    uint256 internal constant WAD = 1e18;
    // Comet price scale (1e8 == $1) and the UNI factors verified on the live USDC Comet.
    uint256 internal constant PRICE_SCALE = 1e8;
    uint64 internal constant UNI_BORROW_CF = 0.68e18;
    uint64 internal constant UNI_LIQUIDATE_CF = 0.74e18;

    MockComet internal comet;
    CompoundV3LendingAdapter internal adapter;

    address internal gov = makeAddr("gov");
    address internal stranger = makeAddr("stranger");
    address internal account = address(this); // encoders assert account == msg.sender for withdraw

    // Long UNI market: supply UNI collateral, borrow USDC (the Comet base).
    MockERC20 internal uni;
    MockERC20 internal usdc;
    address internal uniFeed = makeAddr("uniFeed");
    address internal usdcFeed = makeAddr("usdcFeed");
    Market internal market;
    Market internal unrouted; // debt not the base token

    function setUp() public {
        uni = new MockERC20("Uniswap", "UNI", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        comet = new MockComet(address(usdc), usdcFeed, 1e6);
        comet.registerCollateral(address(uni), uniFeed, 1e18, UNI_BORROW_CF, UNI_LIQUIDATE_CF);
        comet.setPrice(uniFeed, 7 * PRICE_SCALE); // UNI = $7
        comet.setPrice(usdcFeed, 1 * PRICE_SCALE); // USDC = $1

        adapter = new CompoundV3LendingAdapter(comet, gov);

        market = Market({collateral: Currency.wrap(address(uni)), debt: Currency.wrap(address(usdc))});
        unrouted = Market({collateral: Currency.wrap(address(usdc)), debt: Currency.wrap(address(uni))});

        vm.prank(gov);
        adapter.setMarket(market.collateral, market.debt, true);
    }

    // ---- construction ----

    function test_constructor_bindsCometAndBase() public view {
        assertEq(address(adapter.comet()), address(comet));
        assertEq(adapter.baseToken(), address(usdc));
        assertEq(adapter.lendingProtocol(), address(comet));
        assertEq(adapter.owner(), gov);
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert(ZeroOwner.selector);
        new CompoundV3LendingAdapter(comet, address(0));
    }

    // ---- setMarket validation ----

    function test_setMarket_enablesValidPair() public view {
        assertTrue(adapter.isSupportedMarket(market));
    }

    function test_setMarket_revertsWhenNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotOwner.selector, stranger));
        adapter.setMarket(market.collateral, market.debt, true);
    }

    function test_setMarket_revertsWhenDebtNotBaseToken() public {
        // debt = UNI is not the Comet base (USDC)
        vm.prank(gov);
        vm.expectRevert(
            abi.encodeWithSelector(
                CompoundV3LendingAdapter.DebtNotBaseToken.selector, Currency.wrap(address(uni)), address(usdc)
            )
        );
        adapter.setMarket(Currency.wrap(address(uni)), Currency.wrap(address(uni)), true);
    }

    function test_setMarket_revertsWhenCollateralNotACometAsset() public {
        MockERC20 rando = new MockERC20("Rando", "RND", 18);
        vm.prank(gov);
        vm.expectRevert(
            abi.encodeWithSelector(
                CompoundV3LendingAdapter.MarketNotSupported.selector,
                Currency.wrap(address(rando)),
                Currency.wrap(address(usdc))
            )
        );
        adapter.setMarket(Currency.wrap(address(rando)), Currency.wrap(address(usdc)), true);
    }

    function test_setMarket_disableSkipsValidation() public {
        // disabling never validates: a bad pair can always be turned off
        vm.prank(gov);
        adapter.setMarket(Currency.wrap(address(uni)), Currency.wrap(address(uni)), false);
        assertFalse(adapter.isSupportedMarket(Market({collateral: market.collateral, debt: market.collateral})));
    }

    // ---- encoders ----

    function test_encodeSupplyCollateral_suppliesCollateralToComet() public view {
        (address target, uint256 value, bytes memory data) = adapter.encodeSupplyCollateral(account, market, 100e18);
        assertEq(target, address(comet));
        assertEq(value, 0);
        assertEq(data, abi.encodeCall(IComet.supply, (address(uni), 100e18)));
    }

    function test_encodeBorrow_withdrawsBaseFromComet() public view {
        (address target,, bytes memory data) = adapter.encodeBorrow(account, market, 500e6);
        assertEq(target, address(comet));
        assertEq(data, abi.encodeCall(IComet.withdraw, (address(usdc), 500e6)));
    }

    function test_encodeWithdrawCollateral_withdrawsToReceiver() public view {
        (address target,, bytes memory data) = adapter.encodeWithdrawCollateral(account, market, 100e18, stranger);
        assertEq(target, address(comet));
        assertEq(data, abi.encodeCall(IComet.withdrawTo, (stranger, address(uni), 100e18)));
    }

    function test_encodeWithdrawCollateral_revertsOnAccountMismatch() public {
        vm.expectRevert(
            abi.encodeWithSelector(CompoundV3LendingAdapter.AccountMismatch.selector, stranger, address(this))
        );
        adapter.encodeWithdrawCollateral(stranger, market, 100e18, stranger);
    }

    function test_encodeRepay_partialSuppliesRequestedAmountUpToBorrow() public {
        comet.setBorrowBalance(account, 1_000e6);
        // a partial repay at or below the outstanding borrow supplies exactly the requested amount
        (address target,, bytes memory data) = adapter.encodeRepay(account, market, 250e6);
        assertEq(target, address(comet));
        assertEq(data, abi.encodeCall(IComet.supply, (address(usdc), 250e6)));
    }

    function test_encodeRepay_capsSupplyAtOutstandingBorrow() public {
        comet.setBorrowBalance(account, 1_000e6);
        // an over-sized repay is capped at the borrow, so the overshoot is never supplied as base and
        // cannot be stranded as an unintended positive base-supply position
        (,, bytes memory data) = adapter.encodeRepay(account, market, 2_000e6);
        assertEq(data, abi.encodeCall(IComet.supply, (address(usdc), 1_000e6)));
    }

    function test_encodeRepay_maxSuppliesAccruedBorrow() public {
        comet.setBorrowBalance(account, 777e6);
        (,, bytes memory data) = adapter.encodeRepay(account, market, type(uint256).max);
        assertEq(data, abi.encodeCall(IComet.supply, (address(usdc), 777e6)));
    }

    // ---- reads ----

    function test_positionOf_returnsCollateralAndBorrow() public {
        comet.setCollateralBalance(account, address(uni), 1_000e18);
        comet.setBorrowBalance(account, 3_500e6);
        (uint256 coll, uint256 debt) = adapter.positionOf(account, market);
        assertEq(coll, 1_000e18);
        assertEq(debt, 3_500e6);
    }

    function test_maxLtvWad_isLiquidateCollateralFactor() public view {
        assertEq(Ltv.unwrap(adapter.maxLtvWad(market)), UNI_LIQUIDATE_CF);
    }

    function test_currentLtvWad_valuesInUsd() public {
        // 1000 UNI @ $7 = $7000 collateral; 3500 USDC @ $1 = $3500 debt -> LTV 50%
        comet.setCollateralBalance(account, address(uni), 1_000e18);
        comet.setBorrowBalance(account, 3_500e6);
        assertApproxEqAbs(raw(adapter.currentLtvWad(account, market)), 0.5e18, 1);
    }

    function test_currentLtvWad_zeroDebtIsZero() public {
        comet.setCollateralBalance(account, address(uni), 1_000e18);
        assertEq(raw(adapter.currentLtvWad(account, market)), 0);
    }

    function test_currentLtvWad_debtWithoutCollateralIsMax() public {
        comet.setBorrowBalance(account, 1e6);
        assertEq(raw(adapter.currentLtvWad(account, market)), type(uint256).max);
    }

    function test_describePosition_derivesAllFields() public {
        comet.setCollateralBalance(account, address(uni), 1_000e18);
        comet.setBorrowBalance(account, 3_500e6);
        PositionData memory d = adapter.describePosition(account, market);
        assertEq(d.collateralAmount, 1_000e18);
        assertEq(d.debtAmount, 3_500e6);
        assertEq(Ltv.unwrap(d.maxLtv), UNI_LIQUIDATE_CF);
        assertApproxEqAbs(raw(d.currentLtv), 0.5e18, 1);
        // health = liquidateCF * collateralValue / debtValue = 0.74 * 7000 / 3500 = 1.48
        assertApproxEqAbs(d.healthFactorWad, 1.48e18, 1e6);
    }

    function test_describePosition_zeroDebtHealthIsMax() public {
        comet.setCollateralBalance(account, address(uni), 1_000e18);
        PositionData memory d = adapter.describePosition(account, market);
        assertEq(d.healthFactorWad, type(uint256).max);
    }

    // ---- unrouted market guard: every entrypoint reverts ----

    function test_unroutedMarket_revertsEverywhere() public {
        bytes memory err = abi.encodeWithSelector(
            CompoundV3LendingAdapter.MarketNotSupported.selector, unrouted.collateral, unrouted.debt
        );
        vm.expectRevert(err);
        adapter.encodeSupplyCollateral(account, unrouted, 1);
        vm.expectRevert(err);
        adapter.encodeWithdrawCollateral(account, unrouted, 1, account);
        vm.expectRevert(err);
        adapter.encodeBorrow(account, unrouted, 1);
        vm.expectRevert(err);
        adapter.encodeRepay(account, unrouted, 1);
        vm.expectRevert(err);
        adapter.positionOf(account, unrouted);
        vm.expectRevert(err);
        adapter.maxLtvWad(unrouted);
        vm.expectRevert(err);
        adapter.currentLtvWad(account, unrouted);
        vm.expectRevert(err);
        adapter.describePosition(account, unrouted);
    }
}
