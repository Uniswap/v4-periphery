// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {AaveLendingAdapter} from "../../src/AaveLendingAdapter.sol";
import {IPool} from "../../src/interfaces/external/aave/IPool.sol";
import {IPoolAddressesProvider} from "../../src/interfaces/external/aave/IPoolAddressesProvider.sol";
import {Market} from "../../src/types/Market.sol";
import {NotOwner, ZeroOwner, NotPendingOwner} from "../../src/types/Owner.sol";
import {Ltv} from "../../src/types/Ltv.sol";
import {MockAavePool, MockAaveAddressesProvider, MockAaveDataProvider} from "../mocks/MockAavePool.sol";

contract AaveLendingAdapterTest is Test {
    // WAD scale for loan-to-value ratios (1e18 == 100%).
    uint256 internal constant WAD = 1e18;
    // USD base used by the mock pool's account data (8 decimals; 1e8 == $1).
    uint256 internal constant USD_BASE = 1e8;
    // USDC liquidation threshold in basis points for the short market.
    uint256 internal constant USDC_LIQ_THRESHOLD_BPS = 7_800;
    // WETH liquidation threshold in basis points (distinct from USDC's so a mixup would surface).
    uint256 internal constant WETH_LIQ_THRESHOLD_BPS = 8_000;

    MockAavePool internal pool;
    MockAaveAddressesProvider internal provider;
    MockAaveDataProvider internal dataProvider;
    AaveLendingAdapter internal adapter;

    address internal gov = makeAddr("gov");
    address internal stranger = makeAddr("stranger");
    address internal account = makeAddr("account");

    // Short ETH market: supply USDC collateral, borrow WETH debt.
    MockERC20 internal usdc;
    MockERC20 internal weth;
    Market internal market;
    // An unrouted pair (reversed market) used to assert every entrypoint reverts when not allowlisted.
    Market internal unroutedMarket;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        // Deploy in dependency order: the pool first, then the data provider and provider over it.
        pool = new MockAavePool();
        dataProvider = new MockAaveDataProvider(pool);
        provider = new MockAaveAddressesProvider(address(pool), address(dataProvider));

        _registerReserve(usdc, 1 * USD_BASE, USDC_LIQ_THRESHOLD_BPS);
        _registerReserve(weth, 2_000 * USD_BASE, WETH_LIQ_THRESHOLD_BPS);

        adapter = new AaveLendingAdapter(IPoolAddressesProvider(address(provider)), gov);

        market = Market({collateral: Currency.wrap(address(usdc)), debt: Currency.wrap(address(weth))});
        unroutedMarket = Market({collateral: Currency.wrap(address(weth)), debt: Currency.wrap(address(usdc))});

        vm.prank(gov);
        adapter.setMarket(market.collateral, market.debt, true);
    }

    function _registerReserve(MockERC20 asset, uint256 priceBase, uint256 liquidationThresholdBps) internal {
        MockERC20 aToken = new MockERC20("aToken", "aTKN", asset.decimals());
        MockERC20 vDebt = new MockERC20("variableDebt", "vDEBT", asset.decimals());
        pool.registerReserve(address(asset), aToken, vDebt, priceBase, liquidationThresholdBps);
    }

    // Drives the mock pool directly to set up a position: mint collateral aTokens and debt receipts.
    function _seedPosition(uint256 collateralAmount, uint256 debtAmount) internal {
        if (collateralAmount != 0) pool.aToken(address(usdc)).mint(account, collateralAmount);
        if (debtAmount != 0) pool.variableDebtToken(address(weth)).mint(account, debtAmount);
    }

    // calldata decode helpers (slice the 4-byte selector, then abi.decode the args)
    function decodeSupply(bytes calldata d)
        external
        pure
        returns (address asset, uint256 amount, address onBehalfOf, uint16 referralCode)
    {
        (asset, amount, onBehalfOf, referralCode) = abi.decode(d[4:], (address, uint256, address, uint16));
    }

    function decodeWithdraw(bytes calldata d) external pure returns (address asset, uint256 amount, address to) {
        (asset, amount, to) = abi.decode(d[4:], (address, uint256, address));
    }

    function decodeBorrow(bytes calldata d)
        external
        pure
        returns (address asset, uint256 amount, uint256 rateMode, uint16 referralCode, address onBehalfOf)
    {
        (asset, amount, rateMode, referralCode, onBehalfOf) =
            abi.decode(d[4:], (address, uint256, uint256, uint16, address));
    }

    function decodeRepay(bytes calldata d)
        external
        pure
        returns (address asset, uint256 amount, uint256 rateMode, address onBehalfOf)
    {
        (asset, amount, rateMode, onBehalfOf) = abi.decode(d[4:], (address, uint256, uint256, address));
    }

    function test_lendingProtocol_returnsPool() public view {
        assertEq(adapter.lendingProtocol(), address(pool));
    }

    function test_owner_isConstructorOwner() public view {
        assertEq(adapter.owner(), gov);
    }

    function test_encodeSupplyCollateral_targetSelectorAndArgs() public view {
        (address target, uint256 value, bytes memory data) = adapter.encodeSupplyCollateral(account, market, 1_000e6);
        assertEq(target, address(pool));
        assertEq(value, 0);
        assertEq(bytes4(data), IPool.supply.selector);
        (address asset, uint256 amount, address onBehalfOf, uint16 referralCode) = this.decodeSupply(data);
        assertEq(asset, address(usdc));
        assertEq(amount, 1_000e6);
        assertEq(onBehalfOf, account); // the account is always the onBehalf
        assertEq(referralCode, 0);
    }

    function test_encodeWithdrawCollateral_honorsReceiver() public {
        address receiver = makeAddr("receiver");
        // Aave withdraw burns the caller's own aTokens, so the account must be the caller
        vm.prank(account);
        (address target, uint256 value, bytes memory data) =
            adapter.encodeWithdrawCollateral(account, market, 500e6, receiver);
        assertEq(target, address(pool));
        assertEq(value, 0);
        assertEq(bytes4(data), IPool.withdraw.selector);
        (address asset, uint256 amount, address to) = this.decodeWithdraw(data);
        assertEq(asset, address(usdc));
        assertEq(amount, 500e6);
        assertEq(to, receiver); // Aave withdraw honors the to recipient directly
    }

    function test_encodeWithdrawCollateral_revertsWhenAccountNotCaller() public {
        // the encoder only produces a withdrawal for the account that calls it
        vm.expectRevert(abi.encodeWithSelector(AaveLendingAdapter.AccountMismatch.selector, account, address(this)));
        adapter.encodeWithdrawCollateral(account, market, 500e6, account);
    }

    function test_encodeBorrow_onBehalfIsAccountAndNoReceiver() public view {
        (address target, uint256 value, bytes memory data) = adapter.encodeBorrow(account, market, 0.5e18);
        assertEq(target, address(pool));
        assertEq(value, 0);
        assertEq(bytes4(data), IPool.borrow.selector);
        (address asset, uint256 amount, uint256 rateMode, uint16 referralCode, address onBehalfOf) =
            this.decodeBorrow(data);
        assertEq(asset, address(weth));
        assertEq(amount, 0.5e18);
        assertEq(rateMode, 2); // variable rate
        assertEq(referralCode, 0);
        // the borrow accrues debt to the account and delivers the asset to msg.sender (the account),
        // which forwards it; there is no receiver parameter to assert
        assertEq(onBehalfOf, account);
    }

    function test_encodeRepay_exactAmount() public view {
        (address target, uint256 value, bytes memory data) = adapter.encodeRepay(account, market, 0.25e18);
        assertEq(target, address(pool));
        assertEq(value, 0);
        assertEq(bytes4(data), IPool.repay.selector);
        (address asset, uint256 amount, uint256 rateMode, address onBehalfOf) = this.decodeRepay(data);
        assertEq(asset, address(weth));
        assertEq(amount, 0.25e18);
        assertEq(rateMode, 2);
        assertEq(onBehalfOf, account);
    }

    function test_encodeRepay_max() public view {
        (,, bytes memory data) = adapter.encodeRepay(account, market, type(uint256).max);
        (, uint256 amount,,) = this.decodeRepay(data);
        assertEq(amount, type(uint256).max); // max repays the full variable debt natively
    }

    function test_positionOf_reflectsReceiptBalances() public {
        _seedPosition(1_000e6, 0.3e18);
        (uint256 collateralAmount, uint256 debtAmount) = adapter.positionOf(account, market);
        assertEq(collateralAmount, 1_000e6);
        assertEq(debtAmount, 0.3e18);
    }

    function test_positionOf_zeroForFreshAccount() public view {
        (uint256 collateralAmount, uint256 debtAmount) = adapter.positionOf(account, market);
        assertEq(collateralAmount, 0);
        assertEq(debtAmount, 0);
    }

    function test_maxLtvWad_usesLiquidationThresholdNotLtv() public view {
        // 7800 bps liquidation threshold -> 0.78e18; the ltv field is 7600 bps, so a mixup would fail
        assertEq(Ltv.unwrap(adapter.maxLtvWad(market)), USDC_LIQ_THRESHOLD_BPS * WAD / 1e4);
        assertEq(Ltv.unwrap(adapter.maxLtvWad(market)), 0.78e18);
    }

    function test_currentLtvWad_forSetUpPosition() public {
        // 1000 USDC collateral ($1000) and 0.3 WETH debt ($600) -> LTV 0.6e18
        _seedPosition(1_000e6, 0.3e18);
        assertEq(Ltv.unwrap(adapter.currentLtvWad(account, market)), 0.6e18);
    }

    function test_currentLtvWad_zeroWhenNoDebt() public {
        _seedPosition(1_000e6, 0);
        assertEq(Ltv.unwrap(adapter.currentLtvWad(account, market)), 0);
    }

    function test_currentLtvWad_maxWhenDebtWithoutCollateral() public {
        _seedPosition(0, 0.3e18);
        assertEq(Ltv.unwrap(adapter.currentLtvWad(account, market)), type(uint256).max);
    }

    function test_isSupportedMarket_trueForRegisteredFalseOtherwise() public view {
        assertTrue(adapter.isSupportedMarket(market));
        assertFalse(adapter.isSupportedMarket(unroutedMarket));
    }

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

    function test_setMarket_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotOwner.selector, stranger));
        adapter.setMarket(market.collateral, market.debt, true);
    }

    function test_setMarket_revertsForUnlistedReserve() public {
        MockERC20 unlisted = new MockERC20("Unlisted", "UNL", 18);
        Currency unlistedCurrency = Currency.wrap(address(unlisted));
        vm.prank(gov);
        vm.expectRevert(
            abi.encodeWithSelector(AaveLendingAdapter.MarketNotSupported.selector, unlistedCurrency, market.debt)
        );
        adapter.setMarket(unlistedCurrency, market.debt, true);
    }

    function test_setMarket_disableSucceeds() public {
        vm.prank(gov);
        adapter.setMarket(market.collateral, market.debt, false);
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
        // the owner is unchanged until the successor accepts
        assertEq(adapter.owner(), gov);
        assertEq(adapter.pendingOwner(), newOwner);
    }

    function test_oldOwnerRetainsPowerUntilAccept() public {
        vm.prank(gov);
        adapter.transferOwnership(makeAddr("newOwner"));
        // the old owner can still configure markets before the handoff completes
        vm.prank(gov);
        adapter.setMarket(market.collateral, market.debt, false);
        assertFalse(adapter.isSupportedMarket(market));
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

    function test_acceptOwnership_revertsWhenNonePending() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotPendingOwner.selector, stranger));
        adapter.acceptOwnership();
    }

    function _expectMarketNotSupported(Market memory m) internal {
        vm.expectRevert(abi.encodeWithSelector(AaveLendingAdapter.MarketNotSupported.selector, m.collateral, m.debt));
    }
}
