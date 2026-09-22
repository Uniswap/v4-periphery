// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {CompoundV3LendingAdapter} from "../../src/CompoundV3LendingAdapter.sol";
import {ILendingAdapter} from "../../src/interfaces/ILendingAdapter.sol";
import {IComet} from "../../src/interfaces/external/compound-v3/IComet.sol";
import {PositionAmountResolver} from "../../src/base/PositionAmountResolver.sol";
import {Market} from "../../src/types/Market.sol";
import {Ltv} from "../../src/types/Ltv.sol";
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

    address internal stranger = makeAddr("stranger");
    address internal account = address(this); // encoders assert account == msg.sender for withdraw

    // Long UNI market: supply UNI collateral, borrow USDC (the Comet base).
    MockERC20 internal uni;
    MockERC20 internal usdc;
    MockERC20 internal rando; // never listed on the Comet
    address internal uniFeed = makeAddr("uniFeed");
    address internal usdcFeed = makeAddr("usdcFeed");
    Market internal market;
    Market internal debtNotBase; // debt is a collateral asset, not the Comet base
    Market internal unlisted; // collateral the Comet does not list

    function setUp() public {
        uni = new MockERC20("Uniswap", "UNI", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        rando = new MockERC20("Rando", "RND", 18);

        comet = new MockComet(address(usdc), usdcFeed, 1e6);
        comet.registerCollateral(address(uni), uniFeed, 1e18, UNI_BORROW_CF, UNI_LIQUIDATE_CF);
        comet.setPrice(uniFeed, 7 * PRICE_SCALE); // UNI = $7
        comet.setPrice(usdcFeed, 1 * PRICE_SCALE); // USDC = $1

        adapter = new CompoundV3LendingAdapter(comet);

        // a Comet market is the collateral asset alone, so the key carries no data
        market = Market({collateral: Currency.wrap(address(uni)), debt: Currency.wrap(address(usdc)), data: ""});
        debtNotBase = Market({collateral: Currency.wrap(address(usdc)), debt: Currency.wrap(address(uni)), data: ""});
        unlisted = Market({collateral: Currency.wrap(address(rando)), debt: Currency.wrap(address(usdc)), data: ""});
    }

    /// @dev Asserts every validating entry point rejects `bad` with exactly `err`. `encodeEnableCollateral`
    ///      is excluded: it is a documented pure no-op on Comet and decodes nothing.
    function _assertRevertsEverywhere(Market memory bad, bytes memory err) internal {
        vm.expectRevert(err);
        adapter.encodeSupplyCollateral(account, bad, 1);
        vm.expectRevert(err);
        adapter.encodeWithdrawCollateral(account, bad, 1, account);
        vm.expectRevert(err);
        adapter.encodeBorrow(account, bad, 1);
        vm.expectRevert(err);
        adapter.encodeRepay(account, bad, 1);
        vm.expectRevert(err);
        adapter.positionOf(account, bad);
        vm.expectRevert(err);
        adapter.maxLtvWad(bad);
        vm.expectRevert(err);
        adapter.currentLtvWad(account, bad);
        vm.expectRevert(err);
        adapter.describePosition(account, bad);
        vm.expectRevert(err);
        adapter.resolveAmount(abi.encode(PositionAmountResolver.PositionAmount.DEBT, account, bad));
    }

    // ---- construction ----

    function test_constructor_bindsCometAndBase() public view {
        assertEq(address(adapter.comet()), address(comet));
        assertEq(adapter.baseToken(), address(usdc));
        assertEq(adapter.baseScale(), 1e6);
        assertEq(adapter.lendingProtocol(), address(comet));
    }

    function test_constructor_revertsOnZeroBaseToken() public {
        MockComet zeroBase = new MockComet(address(0), usdcFeed, 1e6);
        vm.expectRevert(CompoundV3LendingAdapter.ZeroAddress.selector);
        new CompoundV3LendingAdapter(zeroBase);
    }

    // ---- key validation: empty data, debt == base, collateral listed on the Comet ----

    function test_isSupportedMarket_trueForListedCollateralAndBase() public view {
        assertTrue(adapter.isSupportedMarket(market));
    }

    function test_isSupportedMarket_falseWhenDebtNotBaseToken() public view {
        assertFalse(adapter.isSupportedMarket(debtNotBase));
    }

    /// @dev The Comet reverts `getAssetInfoByAddress` for an unlisted asset; the probe swallows that and
    ///      reports the key unroutable rather than bubbling the venue error.
    function test_isSupportedMarket_falseWhenCollateralNotListed() public view {
        assertFalse(adapter.isSupportedMarket(unlisted));
    }

    function test_isSupportedMarket_falseForNonEmptyData() public view {
        Market memory withData = Market({collateral: market.collateral, debt: market.debt, data: hex"01"});
        assertFalse(adapter.isSupportedMarket(withData));
    }

    /// @dev The hazard the base check exists for: Comet's `withdraw(asset)` of a COLLATERAL asset is a
    ///      collateral withdrawal, so a key naming a collateral asset as the debt must never be encoded
    ///      as a borrow of it. The Comet can only borrow its single base.
    function test_encodeBorrow_revertsWhenDebtNotBaseToken() public {
        Market memory collateralAsDebt =
            Market({collateral: Currency.wrap(address(uni)), debt: Currency.wrap(address(uni)), data: ""});
        vm.expectRevert(
            abi.encodeWithSelector(
                CompoundV3LendingAdapter.DebtNotBaseToken.selector, Currency.wrap(address(uni)), address(usdc)
            )
        );
        adapter.encodeBorrow(account, collateralAsDebt, 500e6);
    }

    function test_maxLtvWad_revertsWhenDebtNotBaseToken() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CompoundV3LendingAdapter.DebtNotBaseToken.selector, Currency.wrap(address(uni)), address(usdc)
            )
        );
        adapter.maxLtvWad(debtNotBase);
    }

    function test_debtNotBaseToken_revertsEverywhere() public {
        _assertRevertsEverywhere(
            debtNotBase,
            abi.encodeWithSelector(
                CompoundV3LendingAdapter.DebtNotBaseToken.selector, Currency.wrap(address(uni)), address(usdc)
            )
        );
    }

    function test_encodeSupplyCollateral_revertsWhenCollateralNotListed() public {
        vm.expectRevert(
            abi.encodeWithSelector(ILendingAdapter.MarketNotSupported.selector, unlisted.collateral, unlisted.debt)
        );
        adapter.encodeSupplyCollateral(account, unlisted, 100e18);
    }

    function test_positionOf_revertsWhenCollateralNotListed() public {
        vm.expectRevert(
            abi.encodeWithSelector(ILendingAdapter.MarketNotSupported.selector, unlisted.collateral, unlisted.debt)
        );
        adapter.positionOf(account, unlisted);
    }

    function test_unlistedCollateral_revertsEverywhere() public {
        _assertRevertsEverywhere(
            unlisted,
            abi.encodeWithSelector(ILendingAdapter.MarketNotSupported.selector, unlisted.collateral, unlisted.debt)
        );
    }

    /// @dev A Comet market is keyed by the collateral asset alone, so there is exactly one encoding of
    ///      each key: any non-empty data is rejected before the venue is consulted.
    function test_encodeBorrow_revertsOnNonEmptyMarketData() public {
        Market memory withData = Market({collateral: market.collateral, debt: market.debt, data: new bytes(32)});
        vm.expectRevert(abi.encodeWithSelector(ILendingAdapter.InvalidMarketData.selector, 32));
        adapter.encodeBorrow(account, withData, 500e6);
    }

    function test_describePosition_revertsOnNonEmptyMarketData() public {
        Market memory withData = Market({collateral: market.collateral, debt: market.debt, data: hex"c0ffee"});
        vm.expectRevert(abi.encodeWithSelector(ILendingAdapter.InvalidMarketData.selector, 3));
        adapter.describePosition(account, withData);
    }

    function test_nonEmptyMarketData_revertsEverywhere() public {
        Market memory withData = Market({collateral: market.collateral, debt: market.debt, data: new bytes(96)});
        _assertRevertsEverywhere(withData, abi.encodeWithSelector(ILendingAdapter.InvalidMarketData.selector, 96));
    }

    // ---- encoders ----

    function test_encodeSupplyCollateral_suppliesCollateralToComet() public view {
        (address target, uint256 value, bytes memory data) = adapter.encodeSupplyCollateral(account, market, 100e18);
        assertEq(target, address(comet));
        assertEq(value, 0);
        assertEq(data, abi.encodeCall(IComet.supply, (address(uni), 100e18)));
    }

    /// @dev Comet counts supplied collateral automatically, so the enable step is the empty skip signal.
    function test_encodeEnableCollateral_encodesNoOp() public view {
        (address target, uint256 value, bytes memory data) = adapter.encodeEnableCollateral(account, market);
        assertEq(target, address(0));
        assertEq(value, 0);
        assertEq(data.length, 0);
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

    function test_encodeRepay_zeroDebt_encodesNoOp() public view {
        // no borrow seeded: the encoder returns the empty skip signal rather than a zero supply,
        // matching the interface-wide no-op contract shared with the other adapters
        (address target, uint256 value, bytes memory data) = adapter.encodeRepay(account, market, type(uint256).max);
        assertEq(target, address(comet));
        assertEq(value, 0);
        assertEq(data.length, 0, "debt-free repay must be an empty no-op");
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

    function test_resolveAmount_returnsLiveDebt() public {
        comet.setBorrowBalance(account, 3_500e6);
        bytes memory context = abi.encode(PositionAmountResolver.PositionAmount.DEBT, account, market);
        assertEq(adapter.resolveAmount(context), 3_500e6, "resolver reads the accrued base borrow");
    }

    function test_maxLtvWad_isLiquidateCollateralFactor() public view {
        assertEq(Ltv.unwrap(adapter.maxLtvWad(market)), UNI_LIQUIDATE_CF);
    }

    function test_currentLtvWad_valuesInUsd() public {
        // 1000 UNI @ $7 = $7000 collateral; 3500 USDC @ $1 = $3500 debt -> LTV 50%
        comet.setCollateralBalance(account, address(uni), 1_000e18);
        comet.setBorrowBalance(account, 3_500e6);
        assertApproxEqAbs(Ltv.unwrap(adapter.currentLtvWad(account, market)), 0.5e18, 1);
    }

    function test_currentLtvWad_zeroDebtIsZero() public {
        comet.setCollateralBalance(account, address(uni), 1_000e18);
        assertEq(Ltv.unwrap(adapter.currentLtvWad(account, market)), 0);
    }

    function test_currentLtvWad_debtWithoutCollateralIsMax() public {
        comet.setBorrowBalance(account, 1e6);
        assertEq(Ltv.unwrap(adapter.currentLtvWad(account, market)), type(uint256).max);
    }

    function test_describePosition_derivesAllFields() public {
        comet.setCollateralBalance(account, address(uni), 1_000e18);
        comet.setBorrowBalance(account, 3_500e6);
        PositionData memory d = adapter.describePosition(account, market);
        assertEq(d.collateralAmount, 1_000e18);
        assertEq(d.debtAmount, 3_500e6);
        assertEq(Ltv.unwrap(d.maxLtv), UNI_LIQUIDATE_CF);
        assertApproxEqAbs(Ltv.unwrap(d.currentLtv), 0.5e18, 1);
        // health = liquidateCF * collateralValue / debtValue = 0.74 * 7000 / 3500 = 1.48
        assertApproxEqAbs(d.healthFactorWad, 1.48e18, 1e6);
    }

    /// @dev L-14 regression: the base-token price feed is read fresh from the Comet, not cached, so a
    ///      Comet feed migration is picked up. Before the fix, debt was valued with the superseded feed.
    function test_describePosition_tracksBaseFeedRepoint() public {
        comet.setCollateralBalance(account, address(uni), 1_000e18);
        comet.setBorrowBalance(account, 3_500e6);

        // Comet migrates the base feed; the new feed reports USDC at $2 (a deliberately different price
        // so a stale read would surface), the old feed keeps $1.
        address newUsdcFeed = makeAddr("newUsdcFeed");
        comet.setPrice(newUsdcFeed, 2 * PRICE_SCALE);
        comet.setBaseTokenPriceFeed(newUsdcFeed);

        assertEq(adapter.baseTokenPriceFeed(), newUsdcFeed, "adapter tracks the feed repoint");
        // debtValue now uses the new feed: 3500 USDC * $2 = $7000, equal to collateral value ($7000),
        // so health = liquidateCF * 7000 / 7000 = 0.74 (vs 1.48 under the old $1 feed)
        PositionData memory d = adapter.describePosition(account, market);
        assertApproxEqAbs(d.healthFactorWad, 0.74e18, 1e6, "debt valued with the current feed");
    }

    function test_describePosition_zeroDebtHealthIsMax() public {
        comet.setCollateralBalance(account, address(uni), 1_000e18);
        PositionData memory d = adapter.describePosition(account, market);
        assertEq(d.healthFactorWad, type(uint256).max);
    }

    /// @dev Permissionless routing: a second collateral the Comet lists is routable the moment it is
    ///      listed, with its own factors, and never needed an adapter-side registration.
    function test_newlyListedCollateral_routesWithOwnFactors() public {
        assertFalse(adapter.isSupportedMarket(unlisted), "not routable before the Comet lists it");
        comet.registerCollateral(address(rando), makeAddr("randoFeed"), 1e18, 0.5e18, 0.6e18);
        assertTrue(adapter.isSupportedMarket(unlisted), "routable once listed");
        assertEq(Ltv.unwrap(adapter.maxLtvWad(unlisted)), 0.6e18, "reads the new asset's liquidate factor");
        assertEq(Ltv.unwrap(adapter.maxLtvWad(market)), UNI_LIQUIDATE_CF, "existing market unaffected");
        (,, bytes memory data) = adapter.encodeSupplyCollateral(account, unlisted, 1e18);
        assertEq(data, abi.encodeCall(IComet.supply, (address(rando), 1e18)));
    }
}
