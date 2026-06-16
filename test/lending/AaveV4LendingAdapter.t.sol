// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {AaveV4LendingAdapter} from "../../src/AaveV4LendingAdapter.sol";
import {ISpoke} from "../../src/interfaces/external/aave-v4/ISpoke.sol";
import {Market} from "../../src/types/Market.sol";
import {NotOwner, ZeroOwner, NotPendingOwner} from "../../src/types/Owner.sol";
import {Ltv} from "../../src/types/Ltv.sol";
import {MockAaveV4Spoke} from "../mocks/MockAaveV4Spoke.sol";

contract AaveV4LendingAdapterTest is Test {
    // WAD scale for loan-to-value ratios (1e18 == 100%).
    uint256 internal constant WAD = 1e18;
    // Oracle base used by the mock Spoke (8 decimals; 1e8 == $1).
    uint256 internal constant USD_BASE = 1e8;
    // Reserve ids mirror the live Main Spoke layout: WETH = 0, USDC = 7.
    uint256 internal constant WETH_RESERVE_ID = 0;
    uint256 internal constant USDC_RESERVE_ID = 7;
    // Collateral factors in basis points (distinct so a reserve/key mixup would surface).
    uint16 internal constant USDC_CF_BPS = 7_800;
    uint16 internal constant WETH_CF_BPS = 8_300;

    MockAaveV4Spoke internal spoke;
    AaveV4LendingAdapter internal adapter;

    address internal gov = makeAddr("gov");
    address internal stranger = makeAddr("stranger");
    address internal account = makeAddr("account");
    address internal hub = makeAddr("hub");
    address internal oracle = makeAddr("oracle");

    MockERC20 internal usdc;
    MockERC20 internal weth;
    // Short ETH market: supply USDC collateral, borrow WETH debt.
    Market internal market;
    // Long ETH market: supply WETH collateral, borrow USDC debt (registered too, to check maxLtv keys).
    Market internal longMarket;
    // An unrouted pair used to assert every entrypoint reverts when not registered.
    Market internal unroutedMarket;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        spoke = new MockAaveV4Spoke(oracle);
        spoke.registerReserve(WETH_RESERVE_ID, address(weth), hub, 0, 2_000 * USD_BASE, WETH_CF_BPS);
        spoke.registerReserve(USDC_RESERVE_ID, address(usdc), hub, 5, 1 * USD_BASE, USDC_CF_BPS);

        adapter = new AaveV4LendingAdapter(ISpoke(address(spoke)), gov);

        market = Market({collateral: Currency.wrap(address(usdc)), debt: Currency.wrap(address(weth))});
        longMarket = Market({collateral: Currency.wrap(address(weth)), debt: Currency.wrap(address(usdc))});
        // an unrouted pair: USDC against itself is never registered
        unroutedMarket = Market({collateral: Currency.wrap(address(usdc)), debt: Currency.wrap(address(usdc))});

        vm.startPrank(gov);
        adapter.setMarket(market.collateral, market.debt, USDC_RESERVE_ID, WETH_RESERVE_ID, true);
        adapter.setMarket(longMarket.collateral, longMarket.debt, WETH_RESERVE_ID, USDC_RESERVE_ID, true);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // calldata decode helpers (slice the 4-byte selector, then abi.decode)
    // -------------------------------------------------------------------------

    function decodeMulticall(bytes calldata d) external pure returns (bytes[] memory calls) {
        calls = abi.decode(d[4:], (bytes[]));
    }

    function decodeSupply(bytes calldata d) external pure returns (uint256 reserveId, uint256 amount, address onBehalfOf) {
        (reserveId, amount, onBehalfOf) = abi.decode(d[4:], (uint256, uint256, address));
    }

    function decodeSetCollateral(bytes calldata d)
        external
        pure
        returns (uint256 reserveId, bool usingAsCollateral, address onBehalfOf)
    {
        (reserveId, usingAsCollateral, onBehalfOf) = abi.decode(d[4:], (uint256, bool, address));
    }

    function decodeWithdraw(bytes calldata d) external pure returns (uint256 reserveId, uint256 amount, address onBehalfOf) {
        (reserveId, amount, onBehalfOf) = abi.decode(d[4:], (uint256, uint256, address));
    }

    function decodeBorrow(bytes calldata d) external pure returns (uint256 reserveId, uint256 amount, address onBehalfOf) {
        (reserveId, amount, onBehalfOf) = abi.decode(d[4:], (uint256, uint256, address));
    }

    function decodeRepay(bytes calldata d) external pure returns (uint256 reserveId, uint256 amount, address onBehalfOf) {
        (reserveId, amount, onBehalfOf) = abi.decode(d[4:], (uint256, uint256, address));
    }

    // -------------------------------------------------------------------------
    // wiring + encode shape
    // -------------------------------------------------------------------------

    function test_lendingProtocol_returnsSpoke() public view {
        assertEq(adapter.lendingProtocol(), address(spoke));
    }

    function test_owner_isConstructorOwner() public view {
        assertEq(adapter.owner(), gov);
    }

    function test_encodeSupplyCollateral_wrapsSupplyAndSetCollateralInMulticall() public view {
        (address target, uint256 value, bytes memory data) = adapter.encodeSupplyCollateral(account, market, 1_000e6);
        assertEq(target, address(spoke));
        assertEq(value, 0);
        assertEq(bytes4(data), ISpoke.multicall.selector);

        bytes[] memory calls = this.decodeMulticall(data);
        assertEq(calls.length, 2, "supply + setUsingAsCollateral");

        assertEq(bytes4(calls[0]), ISpoke.supply.selector);
        (uint256 supplyId, uint256 amount, address supplyOnBehalf) = this.decodeSupply(calls[0]);
        assertEq(supplyId, USDC_RESERVE_ID);
        assertEq(amount, 1_000e6);
        assertEq(supplyOnBehalf, account);

        assertEq(bytes4(calls[1]), ISpoke.setUsingAsCollateral.selector);
        (uint256 collId, bool flag, address collOnBehalf) = this.decodeSetCollateral(calls[1]);
        assertEq(collId, USDC_RESERVE_ID);
        assertTrue(flag);
        assertEq(collOnBehalf, account);
    }

    function test_encodeSupplyCollateral_executesSupplyAndEnablesCollateral() public {
        uint256 amount = 1_000e6;
        usdc.mint(account, amount);

        (address target,, bytes memory data) = adapter.encodeSupplyCollateral(account, market, amount);
        vm.startPrank(account);
        usdc.approve(target, amount);
        (bool ok,) = target.call(data);
        vm.stopPrank();

        assertTrue(ok, "encoded multicall executed");
        assertEq(spoke.getUserSuppliedAssets(USDC_RESERVE_ID, account), amount, "supply credited");
        assertTrue(spoke.isUsingAsCollateral(USDC_RESERVE_ID, account), "collateral enabled in the same batch");
        // multicall delegatecalls to self, so the inner supply saw the account as msg.sender and pulled
        // the underlying against the account's allowance to the Spoke
        assertEq(spoke.lastSupplyCaller(), account, "multicall preserved msg.sender");
        assertEq(usdc.balanceOf(account), 0, "underlying pulled from the account");
    }

    function test_encodeWithdrawCollateral_targetSelectorAndArgs() public {
        vm.prank(account);
        (address target, uint256 value, bytes memory data) =
            adapter.encodeWithdrawCollateral(account, market, 500e6, makeAddr("receiver"));
        assertEq(target, address(spoke));
        assertEq(value, 0);
        assertEq(bytes4(data), ISpoke.withdraw.selector);
        // v4 withdraw has no receiver: it delivers to msg.sender (the account); onBehalfOf is the account
        (uint256 reserveId, uint256 amount, address onBehalfOf) = this.decodeWithdraw(data);
        assertEq(reserveId, USDC_RESERVE_ID);
        assertEq(amount, 500e6);
        assertEq(onBehalfOf, account);
    }

    function test_encodeWithdrawCollateral_revertsWhenAccountNotCaller() public {
        vm.expectRevert(abi.encodeWithSelector(AaveV4LendingAdapter.AccountMismatch.selector, account, address(this)));
        adapter.encodeWithdrawCollateral(account, market, 500e6, account);
    }

    function test_encodeBorrow_targetSelectorAndArgs() public view {
        (address target, uint256 value, bytes memory data) = adapter.encodeBorrow(account, market, 0.5e18);
        assertEq(target, address(spoke));
        assertEq(value, 0);
        assertEq(bytes4(data), ISpoke.borrow.selector);
        (uint256 reserveId, uint256 amount, address onBehalfOf) = this.decodeBorrow(data);
        assertEq(reserveId, WETH_RESERVE_ID);
        assertEq(amount, 0.5e18);
        assertEq(onBehalfOf, account);
    }

    function test_encodeRepay_exactAmount() public view {
        (address target, uint256 value, bytes memory data) = adapter.encodeRepay(account, market, 0.25e18);
        assertEq(target, address(spoke));
        assertEq(value, 0);
        assertEq(bytes4(data), ISpoke.repay.selector);
        (uint256 reserveId, uint256 amount, address onBehalfOf) = this.decodeRepay(data);
        assertEq(reserveId, WETH_RESERVE_ID);
        assertEq(amount, 0.25e18);
        assertEq(onBehalfOf, account);
    }

    function test_encodeRepay_max() public view {
        (,, bytes memory data) = adapter.encodeRepay(account, market, type(uint256).max);
        (, uint256 amount,) = this.decodeRepay(data);
        assertEq(amount, type(uint256).max); // the Spoke caps an over-amount to the total debt
    }

    // -------------------------------------------------------------------------
    // reads
    // -------------------------------------------------------------------------

    function test_positionOf_reflectsSuppliedAndTotalDebt() public {
        spoke.seedSupplied(USDC_RESERVE_ID, account, 1_000e6);
        spoke.seedDebt(WETH_RESERVE_ID, account, 0.3e18);
        (uint256 collateralAmount, uint256 debtAmount) = adapter.positionOf(account, market);
        assertEq(collateralAmount, 1_000e6);
        assertEq(debtAmount, 0.3e18); // getUserTotalDebt models drawn + accrued premium
    }

    function test_positionOf_zeroForFreshAccount() public view {
        (uint256 collateralAmount, uint256 debtAmount) = adapter.positionOf(account, market);
        assertEq(collateralAmount, 0);
        assertEq(debtAmount, 0);
    }

    function test_maxLtvWad_usesCollateralReserveFactor() public view {
        // short market collateral is USDC (7800 bps -> 0.78e18)
        assertEq(Ltv.unwrap(adapter.maxLtvWad(market)), USDC_CF_BPS * WAD / 1e4);
        assertEq(Ltv.unwrap(adapter.maxLtvWad(market)), 0.78e18);
        // long market collateral is WETH (8300 bps -> 0.83e18); proves the collateral reserve is read,
        // not the debt reserve
        assertEq(Ltv.unwrap(adapter.maxLtvWad(longMarket)), 0.83e18);
    }

    function test_currentLtvWad_forSetUpPosition() public {
        // 1000 USDC collateral ($1000) and 0.3 WETH debt ($600) -> LTV 0.6e18
        spoke.seedSupplied(USDC_RESERVE_ID, account, 1_000e6);
        spoke.seedDebt(WETH_RESERVE_ID, account, 0.3e18);
        assertEq(Ltv.unwrap(adapter.currentLtvWad(account, market)), 0.6e18);
    }

    function test_currentLtvWad_realScales_halfLtv() public {
        // $10,000 USDC collateral, $5,000 WETH debt (2.5 WETH) -> exactly 0.5e18 at the real
        // Value (USD * 1e8) and RAY (1e27) scales the live Spoke uses
        spoke.seedSupplied(USDC_RESERVE_ID, account, 10_000e6);
        spoke.seedDebt(WETH_RESERVE_ID, account, 2.5e18);
        assertEq(Ltv.unwrap(adapter.currentLtvWad(account, market)), 0.5e18);
    }

    function test_currentLtvWad_zeroWhenNoDebt() public {
        spoke.seedSupplied(USDC_RESERVE_ID, account, 1_000e6);
        assertEq(Ltv.unwrap(adapter.currentLtvWad(account, market)), 0);
    }

    function test_currentLtvWad_maxWhenDebtWithoutCollateral() public {
        spoke.seedDebt(WETH_RESERVE_ID, account, 0.3e18);
        assertEq(Ltv.unwrap(adapter.currentLtvWad(account, market)), type(uint256).max);
    }

    function test_isSupportedMarket_trueForRegisteredFalseOtherwise() public view {
        assertTrue(adapter.isSupportedMarket(market));
        assertTrue(adapter.isSupportedMarket(longMarket));
        assertFalse(adapter.isSupportedMarket(unroutedMarket));
    }

    // -------------------------------------------------------------------------
    // market gating
    // -------------------------------------------------------------------------

    function test_encodeSupplyCollateral_revertsWhenMarketNotSupported() public {
        _expectMarketNotSupported(unroutedMarket);
        adapter.encodeSupplyCollateral(account, unroutedMarket, 1e6);
    }

    function test_encodeWithdrawCollateral_revertsWhenMarketNotSupported() public {
        _expectMarketNotSupported(unroutedMarket);
        adapter.encodeWithdrawCollateral(account, unroutedMarket, 1e6, account);
    }

    function test_encodeBorrow_revertsWhenMarketNotSupported() public {
        _expectMarketNotSupported(unroutedMarket);
        adapter.encodeBorrow(account, unroutedMarket, 1e18);
    }

    function test_encodeRepay_revertsWhenMarketNotSupported() public {
        _expectMarketNotSupported(unroutedMarket);
        adapter.encodeRepay(account, unroutedMarket, 1e18);
    }

    function test_positionOf_revertsWhenMarketNotSupported() public {
        _expectMarketNotSupported(unroutedMarket);
        adapter.positionOf(account, unroutedMarket);
    }

    function test_maxLtvWad_revertsWhenMarketNotSupported() public {
        _expectMarketNotSupported(unroutedMarket);
        adapter.maxLtvWad(unroutedMarket);
    }

    function test_currentLtvWad_revertsWhenMarketNotSupported() public {
        _expectMarketNotSupported(unroutedMarket);
        adapter.currentLtvWad(account, unroutedMarket);
    }

    // -------------------------------------------------------------------------
    // setMarket validation + ownership
    // -------------------------------------------------------------------------

    function test_setMarket_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotOwner.selector, stranger));
        adapter.setMarket(market.collateral, market.debt, USDC_RESERVE_ID, WETH_RESERVE_ID, true);
    }

    function test_setMarket_revertsOnUnderlyingMismatch() public {
        // register USDC currency against the WETH reserve id -> underlying mismatch
        vm.prank(gov);
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4LendingAdapter.ReserveMismatch.selector, WETH_RESERVE_ID, address(weth), address(usdc)
            )
        );
        adapter.setMarket(market.collateral, market.debt, WETH_RESERVE_ID, WETH_RESERVE_ID, true);
    }

    function test_setMarket_revertsOnHubMismatch() public {
        // a reserve on a different Hub cannot share a position with one on the main Hub
        address otherHub = makeAddr("otherHub");
        uint256 otherId = 99;
        MockERC20 dai = new MockERC20("Dai", "DAI", 18);
        spoke.registerReserve(otherId, address(dai), otherHub, 9, 1 * USD_BASE, 8_000);
        Market memory crossHub = Market({collateral: Currency.wrap(address(dai)), debt: Currency.wrap(address(weth))});

        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(AaveV4LendingAdapter.HubMismatch.selector, otherHub, hub));
        adapter.setMarket(crossHub.collateral, crossHub.debt, otherId, WETH_RESERVE_ID, true);
    }

    function test_setMarket_disableClearsRoute() public {
        vm.prank(gov);
        adapter.setMarket(market.collateral, market.debt, USDC_RESERVE_ID, WETH_RESERVE_ID, false);
        assertFalse(adapter.isSupportedMarket(market));
    }

    function test_transferOwnership_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotOwner.selector, stranger));
        adapter.transferOwnership(makeAddr("newOwner"));
    }

    function test_transferOwnership_revertsForZeroAddress() public {
        vm.prank(gov);
        vm.expectRevert(ZeroOwner.selector);
        adapter.transferOwnership(address(0));
    }

    function test_transferOwnership_proposesWithoutChangingOwner() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(gov);
        adapter.transferOwnership(newOwner);
        assertEq(adapter.owner(), gov);
        assertEq(adapter.pendingOwner(), newOwner);
    }

    function test_acceptOwnership_completesHandoff() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(gov);
        adapter.transferOwnership(newOwner);

        vm.prank(newOwner);
        adapter.acceptOwnership();

        assertEq(adapter.owner(), newOwner);
        assertEq(adapter.pendingOwner(), address(0));
    }

    function test_acceptOwnership_revertsForNonPendingCaller() public {
        vm.prank(gov);
        adapter.transferOwnership(makeAddr("newOwner"));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotPendingOwner.selector, stranger));
        adapter.acceptOwnership();
    }

    function _expectMarketNotSupported(Market memory m) internal {
        vm.expectRevert(abi.encodeWithSelector(AaveV4LendingAdapter.MarketNotSupported.selector, m.collateral, m.debt));
    }
}
