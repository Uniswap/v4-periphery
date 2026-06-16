// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {AaveLendingAdapter} from "../../src/AaveLendingAdapter.sol";
import {IPool} from "../../src/interfaces/external/aave/IPool.sol";
import {IPoolAddressesProvider} from "../../src/interfaces/external/aave/IPoolAddressesProvider.sol";
import {Market} from "../../src/types/Market.sol";
import {NotOwner, NotPendingOwner} from "../../src/types/Owner.sol";
import {Ltv} from "../../src/types/Ltv.sol";
import {MockAavePool, MockAaveAddressesProvider, MockAaveDataProvider} from "../mocks/MockAavePool.sol";

/// @notice Fuzz tests for AaveLendingAdapter — encode* output shape, positionOf
///         receipt-balance reflection, currentLtvWad formula, and access-control gating.
contract AaveLendingAdapterFuzzTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant USD_BASE = 1e8;
    uint256 internal constant USDC_LIQ_BPS = 7_800;
    uint256 internal constant WETH_LIQ_BPS = 8_000;
    uint256 internal constant VARIABLE_RATE = 2;

    // WETH: 18 decimals, price 2000e8. The mock USD-base value is debtAmt * 2000e8 / 1e18.
    // To ensure the USD-base debt value is non-zero (i.e. no integer truncation), require
    // debtAmt >= 1e18 / (2000 * 1e8) + 1 = 5_000_001. We use a rounder lower bound.
    uint256 internal constant MIN_WETH_FOR_NONZERO_USD = 1e10;

    MockAavePool internal pool;
    MockAaveAddressesProvider internal provider;
    MockAaveDataProvider internal dataProvider;
    AaveLendingAdapter internal adapter;

    address internal gov = makeAddr("gov");

    MockERC20 internal usdc;
    MockERC20 internal weth;
    Market internal market;
    Market internal unroutedMarket;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        pool = new MockAavePool();
        dataProvider = new MockAaveDataProvider(pool);
        provider = new MockAaveAddressesProvider(address(pool), address(dataProvider));

        _registerReserve(usdc, 1 * USD_BASE, USDC_LIQ_BPS);
        _registerReserve(weth, 2_000 * USD_BASE, WETH_LIQ_BPS);

        adapter = new AaveLendingAdapter(IPoolAddressesProvider(address(provider)), gov);

        market = Market({collateral: Currency.wrap(address(usdc)), debt: Currency.wrap(address(weth))});
        unroutedMarket = Market({collateral: Currency.wrap(address(weth)), debt: Currency.wrap(address(usdc))});

        vm.prank(gov);
        adapter.setMarket(market.collateral, market.debt, true);
    }

    function _registerReserve(MockERC20 asset, uint256 priceBase, uint256 liqThresholdBps) internal {
        MockERC20 aToken = new MockERC20("aToken", "aTKN", asset.decimals());
        MockERC20 vDebt = new MockERC20("vDebt", "vDEBT", asset.decimals());
        pool.registerReserve(address(asset), aToken, vDebt, priceBase, liqThresholdBps);
    }

    // External calldata-decode helpers.
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

    // -------------------------------------------------------------------------
    // lendingProtocol
    // -------------------------------------------------------------------------

    function testFuzz_lendingProtocol_isPool(address) public view {
        assertEq(adapter.lendingProtocol(), address(pool));
    }

    // -------------------------------------------------------------------------
    // encodeSupplyCollateral
    // -------------------------------------------------------------------------

    function testFuzz_encodeSupplyCollateral_shape(address account, uint256 amount) public view {
        (address target, uint256 value, bytes memory data) = adapter.encodeSupplyCollateral(account, market, amount);
        assertEq(target, address(pool), "target must be pool");
        assertEq(value, 0, "value must be 0");
        assertEq(bytes4(data), IPool.supply.selector, "wrong selector");
        (address asset, uint256 decodedAmount, address onBehalfOf, uint16 referralCode) = this.decodeSupply(data);
        assertEq(asset, address(usdc), "asset must be collateral (USDC)");
        assertEq(decodedAmount, amount, "amount mismatch");
        assertEq(onBehalfOf, account, "onBehalfOf must be account");
        assertEq(referralCode, 0, "referral code must be 0");
    }

    // -------------------------------------------------------------------------
    // encodeWithdrawCollateral
    // -------------------------------------------------------------------------

    function testFuzz_encodeWithdrawCollateral_shape(address account, uint256 amount, address receiver) public {
        vm.prank(account);
        (address target, uint256 value, bytes memory data) =
            adapter.encodeWithdrawCollateral(account, market, amount, receiver);
        assertEq(target, address(pool), "target must be pool");
        assertEq(value, 0, "value must be 0");
        assertEq(bytes4(data), IPool.withdraw.selector, "wrong selector");
        (address asset, uint256 decodedAmount, address to) = this.decodeWithdraw(data);
        assertEq(asset, address(usdc), "asset must be collateral (USDC)");
        assertEq(decodedAmount, amount, "amount mismatch");
        assertEq(to, receiver, "receiver mismatch");
    }

    // -------------------------------------------------------------------------
    // encodeBorrow
    // -------------------------------------------------------------------------

    function testFuzz_encodeBorrow_shape(address account, uint256 amount) public view {
        (address target, uint256 value, bytes memory data) = adapter.encodeBorrow(account, market, amount);
        assertEq(target, address(pool), "target must be pool");
        assertEq(value, 0, "value must be 0");
        assertEq(bytes4(data), IPool.borrow.selector, "wrong selector");
        (address asset, uint256 decodedAmount, uint256 rateMode, uint16 referralCode, address onBehalfOf) =
            this.decodeBorrow(data);
        assertEq(asset, address(weth), "asset must be debt (WETH)");
        assertEq(decodedAmount, amount, "amount mismatch");
        assertEq(rateMode, VARIABLE_RATE, "rate mode must be variable (2)");
        assertEq(referralCode, 0, "referral code must be 0");
        assertEq(onBehalfOf, account, "onBehalfOf must be account");
    }

    // -------------------------------------------------------------------------
    // encodeRepay
    // -------------------------------------------------------------------------

    function testFuzz_encodeRepay_shape(address account, uint256 amount) public view {
        (address target, uint256 value, bytes memory data) = adapter.encodeRepay(account, market, amount);
        assertEq(target, address(pool), "target must be pool");
        assertEq(value, 0, "value must be 0");
        assertEq(bytes4(data), IPool.repay.selector, "wrong selector");
        (address asset, uint256 decodedAmount, uint256 rateMode, address onBehalfOf) = this.decodeRepay(data);
        assertEq(asset, address(weth), "asset must be debt (WETH)");
        assertEq(decodedAmount, amount, "amount mismatch");
        assertEq(rateMode, VARIABLE_RATE, "rate mode must be variable (2)");
        assertEq(onBehalfOf, account, "onBehalfOf must be account");
    }

    // -------------------------------------------------------------------------
    // positionOf — seeded via mock receipt tokens
    // -------------------------------------------------------------------------

    function testFuzz_positionOf_reflectsSeededBalances(uint128 collAmt, uint128 debtAmt) public {
        address account = makeAddr("account");
        if (collAmt != 0) pool.aToken(address(usdc)).mint(account, collAmt);
        if (debtAmt != 0) pool.variableDebtToken(address(weth)).mint(account, debtAmt);

        (uint256 coll, uint256 debt) = adapter.positionOf(account, market);
        assertEq(coll, uint256(collAmt), "collateral mismatch");
        assertEq(debt, uint256(debtAmt), "debt mismatch");
    }

    function testFuzz_positionOf_zeroForFreshAccount(address account) public view {
        (uint256 coll, uint256 debt) = adapter.positionOf(account, market);
        assertEq(coll, 0);
        assertEq(debt, 0);
    }

    // -------------------------------------------------------------------------
    // currentLtvWad formula
    // -------------------------------------------------------------------------

    /// currentLtvWad == totalDebtBase * WAD / totalCollateralBase (Aave USD-base values).
    /// The mock pool computes totals from seeded aToken / vDebt balances and their prices.
    /// We read back the mock's own computed totals and compare against the adapter result.
    function testFuzz_currentLtvWad_matchesFormula(uint64 collAmt, uint64 debtAmt) public {
        address account = makeAddr("ltv_account");
        // USDC: 6 decimals, price 1e8 — collateralBase = collAmt * 1e8 / 1e6 = collAmt * 100
        // WETH: 18 decimals, price 2000e8 — debtBase = debtAmt * 2000e8 / 1e18
        // We avoid the zero-collateral-with-debt edge case here (separate test below).
        vm.assume(collAmt > 0 || debtAmt == 0);

        if (collAmt != 0) pool.aToken(address(usdc)).mint(account, collAmt);
        if (debtAmt != 0) pool.variableDebtToken(address(weth)).mint(account, debtAmt);

        (uint256 totalCollBase, uint256 totalDebtBase,,,,) = pool.getUserAccountData(account);

        Ltv ltv = adapter.currentLtvWad(account, market);

        if (totalDebtBase == 0) {
            assertEq(Ltv.unwrap(ltv), 0, "zero USD-debt => zero ltv");
        } else if (totalCollBase == 0) {
            assertEq(Ltv.unwrap(ltv), type(uint256).max, "USD-debt with no collateral => max ltv");
        } else {
            uint256 expected = totalDebtBase * WAD / totalCollBase;
            assertEq(Ltv.unwrap(ltv), expected, "ltv formula mismatch");
        }
    }

    /// Zero debt => zero LTV (regardless of collateral).
    function testFuzz_currentLtvWad_zeroDebt(uint64 collAmt) public {
        address account = makeAddr("zd_account");
        if (collAmt != 0) pool.aToken(address(usdc)).mint(account, collAmt);
        assertEq(Ltv.unwrap(adapter.currentLtvWad(account, market)), 0);
    }

    /// Debt with no collateral => max LTV.
    /// debtAmt is bounded below MIN_WETH_FOR_NONZERO_USD to avoid integer truncation in
    /// the mock's USD-base calculation (debtAmt * 2000e8 / 1e18 must be > 0).
    function testFuzz_currentLtvWad_debtNoCollateral(uint256 debtAmt) public {
        debtAmt = bound(debtAmt, MIN_WETH_FOR_NONZERO_USD, type(uint64).max);
        address account = makeAddr("dnc_account");
        pool.variableDebtToken(address(weth)).mint(account, debtAmt);
        assertEq(Ltv.unwrap(adapter.currentLtvWad(account, market)), type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // setMarket access control
    // -------------------------------------------------------------------------

    function testFuzz_setMarket_revertsForNonOwner(address caller) public {
        vm.assume(caller != gov);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(NotOwner.selector, caller));
        adapter.setMarket(market.collateral, market.debt, true);
    }

    // -------------------------------------------------------------------------
    // transferOwnership / acceptOwnership
    // -------------------------------------------------------------------------

    function testFuzz_transferOwnership_revertsForNonOwner(address caller, address newOwner) public {
        vm.assume(caller != gov);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(NotOwner.selector, caller));
        adapter.transferOwnership(newOwner);
    }

    function testFuzz_acceptOwnership_revertsForNonPendingCaller(address successor, address other) public {
        vm.assume(successor != address(0));
        vm.assume(other != successor);
        vm.prank(gov);
        adapter.transferOwnership(successor);

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(NotPendingOwner.selector, other));
        adapter.acceptOwnership();
    }
}
