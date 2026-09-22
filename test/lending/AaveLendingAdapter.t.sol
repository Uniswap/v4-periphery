// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {AaveLendingAdapter} from "../../src/AaveLendingAdapter.sol";
import {ILendingAdapter} from "../../src/interfaces/ILendingAdapter.sol";
import {IPool} from "../../src/interfaces/external/aave/IPool.sol";
import {IPoolAddressesProvider} from "../../src/interfaces/external/aave/IPoolAddressesProvider.sol";
import {PositionAmountResolver} from "../../src/base/PositionAmountResolver.sol";
import {Market} from "../../src/types/Market.sol";
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

    address internal account = makeAddr("account");

    MockERC20 internal usdc;
    MockERC20 internal weth;
    // A token that is never registered as an Aave reserve.
    MockERC20 internal unlisted;

    // Short ETH market: supply USDC collateral, borrow WETH debt.
    Market internal market;
    // The reversed live pair (WETH collateral, USDC debt). Market selection is permissionless, so it
    // routes with no registration step: both assets are live reserves.
    Market internal reversedMarket;
    // Pairs naming the unlisted token on one side. The venue has no market for them, so every entry
    // point must revert MarketNotSupported rather than route a default market.
    Market internal unlistedCollateralMarket;
    Market internal unlistedDebtMarket;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        unlisted = new MockERC20("Unlisted", "UNL", 18);

        // Deploy in dependency order: the pool first, then the data provider and provider over it.
        pool = new MockAavePool();
        dataProvider = new MockAaveDataProvider(pool);
        provider = new MockAaveAddressesProvider(address(pool), address(dataProvider));

        _registerReserve(usdc, 1 * USD_BASE, USDC_LIQ_THRESHOLD_BPS);
        _registerReserve(weth, 2_000 * USD_BASE, WETH_LIQ_THRESHOLD_BPS);

        adapter = new AaveLendingAdapter(IPoolAddressesProvider(address(provider)));

        market = _pair(usdc, weth);
        reversedMarket = _pair(weth, usdc);
        unlistedCollateralMarket = _pair(unlisted, weth);
        unlistedDebtMarket = _pair(usdc, unlisted);
    }

    /// @dev Aave v3 keys a market by the asset pair alone, so the key carries no `data`.
    function _pair(MockERC20 collateral, MockERC20 debt) internal pure returns (Market memory) {
        return Market({collateral: Currency.wrap(address(collateral)), debt: Currency.wrap(address(debt)), data: ""});
    }

    /// @dev The live pair with `data` attached: the wrong shape for this adapter.
    function _withData(bytes memory data) internal view returns (Market memory) {
        return Market({collateral: market.collateral, debt: market.debt, data: data});
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

    /// @dev The `resolveAmount` context asking for the debt side of `account`'s position in `m`.
    function _debtContext(Market memory m) internal view returns (bytes memory) {
        return abi.encode(PositionAmountResolver.PositionAmount.DEBT, account, m);
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

    /// @dev Strip the 4-byte selector so the args can be abi.decoded.
    function sliceSelector(bytes calldata d) external pure returns (bytes memory) {
        return d[4:];
    }

    // -------------------------------------------------------------------------
    // wiring + encode shape
    // -------------------------------------------------------------------------

    function test_lendingProtocol_returnsPool() public view {
        assertEq(adapter.lendingProtocol(), address(pool));
    }

    /// @dev M-01 regression: the data provider is resolved from the addresses provider on each use,
    ///      not cached, so an Aave `setPoolDataProvider` repoint is tracked without redeploying the
    ///      adapter (which has no setter and is not upgradeable). Before the fix, the immutable cache
    ///      would keep returning the original provider and strand the adapter.
    function test_dataProvider_repointIsTracked() public {
        assertEq(address(adapter.dataProvider()), address(dataProvider), "initial data provider");

        // Aave redeploys the data provider; the addresses provider now points at a new one over the
        // same Pool (so reserve lookups still resolve).
        MockAaveDataProvider replacement = new MockAaveDataProvider(pool);
        provider.setDataProvider(address(replacement));

        assertEq(address(adapter.dataProvider()), address(replacement), "adapter tracks the repoint");

        // reads route through the new provider and still resolve the position correctly
        _seedPosition(1_000e6, 1e18);
        (uint256 collateralAmount, uint256 debtAmount) = adapter.positionOf(account, market);
        assertEq(collateralAmount, 1_000e6, "collateral read through the repointed provider");
        assertEq(debtAmount, 1e18, "debt read through the repointed provider");
        assertEq(Ltv.unwrap(adapter.maxLtvWad(market)), USDC_LIQ_THRESHOLD_BPS * WAD / 1e4, "maxLtv via new provider");
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

    /// @dev M-02 fix: the adapter encodes an explicit post-supply collateral enable so a prior aToken
    ///      balance (e.g. a dust grief) cannot leave the reserve unflagged.
    function test_encodeEnableCollateral_encodesSetUserUseReserveAsCollateral() public view {
        (address target, uint256 value, bytes memory data) = adapter.encodeEnableCollateral(account, market);
        assertEq(target, address(pool));
        assertEq(value, 0);
        assertEq(bytes4(data), IPool.setUserUseReserveAsCollateral.selector);
        (address asset, bool useAsCollateral) = abi.decode(this.sliceSelector(data), (address, bool));
        assertEq(asset, address(usdc), "enables the collateral reserve");
        assertTrue(useAsCollateral, "enables (not disables) collateral");
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

    function test_encodeRepay_exactAmount() public {
        _seedPosition(0, 1e18); // the encoder no-ops without live variable debt
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

    function test_encodeRepay_max() public {
        _seedPosition(0, 1e18); // the encoder no-ops without live variable debt
        (,, bytes memory data) = adapter.encodeRepay(account, market, type(uint256).max);
        (, uint256 amount,,) = this.decodeRepay(data);
        assertEq(amount, type(uint256).max); // max repays the full variable debt natively
    }

    function test_encodeRepay_zeroDebt_encodesNoOp() public view {
        // no debt seeded: Aave's repay would revert NoDebtOfSelectedType, so the encoder returns the
        // empty skip signal and a generic repay-then-withdraw exit plan runs against a debt-free
        // position, matching the interface-wide no-op contract
        (address target, uint256 value, bytes memory data) = adapter.encodeRepay(account, market, type(uint256).max);
        assertEq(target, address(pool));
        assertEq(value, 0);
        assertEq(data.length, 0, "debt-free repay must be an empty no-op");
    }

    // -------------------------------------------------------------------------
    // reads
    // -------------------------------------------------------------------------

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

    // -------------------------------------------------------------------------
    // market key validation (per call: there is no registration step)
    // -------------------------------------------------------------------------

    function test_isSupportedMarket_trueForLivePairsFalseOtherwise() public view {
        assertTrue(adapter.isSupportedMarket(market), "short pair");
        assertTrue(adapter.isSupportedMarket(reversedMarket), "reversed pair needs no registration");
        assertFalse(adapter.isSupportedMarket(unlistedCollateralMarket), "unlisted collateral");
        assertFalse(adapter.isSupportedMarket(unlistedDebtMarket), "unlisted debt");
        assertFalse(adapter.isSupportedMarket(_withData(abi.encode(uint256(7), uint256(0)))), "non-empty data");
    }

    /// @dev Permissionless selection: the reversed pair routes against its own reserves with no
    ///      registration step, and `maxLtvWad` reads the reserve now on the collateral side.
    function test_reversedPair_routesWithoutRegistration() public view {
        (address target,, bytes memory data) = adapter.encodeSupplyCollateral(account, reversedMarket, 1e18);
        assertEq(target, address(pool));
        (address asset,, address onBehalfOf,) = this.decodeSupply(data);
        assertEq(asset, address(weth), "reversed pair supplies WETH");
        assertEq(onBehalfOf, account);

        (,, data) = adapter.encodeBorrow(account, reversedMarket, 1_000e6);
        (asset,,,,) = this.decodeBorrow(data);
        assertEq(asset, address(usdc), "reversed pair borrows USDC");

        assertEq(Ltv.unwrap(adapter.maxLtvWad(reversedMarket)), WETH_LIQ_THRESHOLD_BPS * WAD / 1e4, "WETH threshold");
        assertEq(Ltv.unwrap(adapter.maxLtvWad(reversedMarket)), 0.8e18);
    }

    /// @dev Aave keys a market by the pair alone, so `data` must be empty. A two-word key (the Aave v4
    ///      shape) handed to this adapter is the likeliest mistake; it must revert with the length it
    ///      saw rather than be ignored.
    function test_encodeSupplyCollateral_revertsOnNonEmptyData() public {
        Market memory keyed = _withData(abi.encode(uint256(7), uint256(0)));
        vm.expectRevert(abi.encodeWithSelector(ILendingAdapter.InvalidMarketData.selector, 64));
        adapter.encodeSupplyCollateral(account, keyed, 1e6);
    }

    function test_positionOf_revertsOnNonEmptyData() public {
        Market memory keyed = _withData(hex"01");
        vm.expectRevert(abi.encodeWithSelector(ILendingAdapter.InvalidMarketData.selector, 1));
        adapter.positionOf(account, keyed);
    }

    function test_encodeSupplyCollateral_revertsWhenMarketNotSupported() public {
        _expectMarketNotSupported(unlistedCollateralMarket);
        adapter.encodeSupplyCollateral(account, unlistedCollateralMarket, 1e6);
    }

    function test_encodeEnableCollateral_revertsWhenMarketNotSupported() public {
        _expectMarketNotSupported(unlistedCollateralMarket);
        adapter.encodeEnableCollateral(account, unlistedCollateralMarket);
    }

    function test_encodeWithdrawCollateral_revertsWhenMarketNotSupported() public {
        // the key is validated before the caller check, so a stranger sees the market error
        _expectMarketNotSupported(unlistedCollateralMarket);
        adapter.encodeWithdrawCollateral(account, unlistedCollateralMarket, 1e6, account);
    }

    function test_encodeBorrow_revertsWhenMarketNotSupported() public {
        _expectMarketNotSupported(unlistedCollateralMarket);
        adapter.encodeBorrow(account, unlistedCollateralMarket, 1e18);
    }

    function test_encodeRepay_revertsWhenMarketNotSupported() public {
        _expectMarketNotSupported(unlistedCollateralMarket);
        adapter.encodeRepay(account, unlistedCollateralMarket, 1e18);
    }

    function test_positionOf_revertsWhenMarketNotSupported() public {
        _expectMarketNotSupported(unlistedCollateralMarket);
        adapter.positionOf(account, unlistedCollateralMarket);
    }

    function test_maxLtvWad_revertsWhenMarketNotSupported() public {
        _expectMarketNotSupported(unlistedCollateralMarket);
        adapter.maxLtvWad(unlistedCollateralMarket);
    }

    function test_currentLtvWad_revertsWhenMarketNotSupported() public {
        _expectMarketNotSupported(unlistedCollateralMarket);
        adapter.currentLtvWad(account, unlistedCollateralMarket);
    }

    function test_describePosition_revertsWhenMarketNotSupported() public {
        _expectMarketNotSupported(unlistedCollateralMarket);
        adapter.describePosition(account, unlistedCollateralMarket);
    }

    function test_resolveAmount_revertsWhenMarketNotSupported() public {
        _expectMarketNotSupported(unlistedCollateralMarket);
        adapter.resolveAmount(_debtContext(unlistedCollateralMarket));
    }

    /// @dev The debt side is checked too: a live collateral paired with an unlisted debt asset is
    ///      rejected on every entry point, not just the debt-side encoders.
    function test_allEntryPoints_revertWhenDebtIsNotAReserve() public {
        Market memory m = unlistedDebtMarket;
        _expectMarketNotSupported(m);
        adapter.encodeSupplyCollateral(account, m, 1e6);
        _expectMarketNotSupported(m);
        adapter.encodeEnableCollateral(account, m);
        _expectMarketNotSupported(m);
        adapter.encodeWithdrawCollateral(account, m, 1e6, account);
        _expectMarketNotSupported(m);
        adapter.encodeBorrow(account, m, 1e18);
        _expectMarketNotSupported(m);
        adapter.encodeRepay(account, m, 1e18);
        _expectMarketNotSupported(m);
        adapter.positionOf(account, m);
        _expectMarketNotSupported(m);
        adapter.maxLtvWad(m);
        _expectMarketNotSupported(m);
        adapter.currentLtvWad(account, m);
        _expectMarketNotSupported(m);
        adapter.describePosition(account, m);
        _expectMarketNotSupported(m);
        adapter.resolveAmount(_debtContext(m));
    }

    function _expectMarketNotSupported(Market memory m) internal {
        vm.expectRevert(abi.encodeWithSelector(ILendingAdapter.MarketNotSupported.selector, m.collateral, m.debt));
    }
}
