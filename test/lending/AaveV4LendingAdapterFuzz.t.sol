// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {AaveV4LendingAdapter} from "../../src/AaveV4LendingAdapter.sol";
import {ILendingAdapter} from "../../src/interfaces/ILendingAdapter.sol";
import {ISpoke} from "../../src/interfaces/external/aave-v4/ISpoke.sol";
import {Market} from "../../src/types/Market.sol";
import {Ltv} from "../../src/types/Ltv.sol";
import {MockAaveV4Spoke} from "../mocks/MockAaveV4Spoke.sol";

/// @notice Fuzz tests for AaveV4LendingAdapter: encode* output shape, the post-supply collateral
///         enable, positionOf seeding, currentLtvWad formula at real Value/RAY scales, and per-call
///         market-key validation.
contract AaveV4LendingAdapterFuzzTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant USD_BASE = 1e8;

    uint256 internal constant WETH_RESERVE_ID = 0;
    uint256 internal constant USDC_RESERVE_ID = 7;
    uint16 internal constant USDC_CF_BPS = 7_800;
    uint16 internal constant WETH_CF_BPS = 8_300;

    // WETH: 18 decimals, price 2000e8. The mock computes value as amount * 2000e8 / 1e18.
    // Minimum debt amount to avoid integer truncation to zero: need amount * 2e11 >= 1e18,
    // i.e. amount >= 5e6. We use a round value with extra margin.
    uint256 internal constant MIN_WETH_FOR_NONZERO_USD = 1e10;

    MockAaveV4Spoke internal spoke;
    AaveV4LendingAdapter internal adapter;

    address internal hub = makeAddr("hub");
    address internal oracle = makeAddr("oracle");

    MockERC20 internal usdc;
    MockERC20 internal weth;
    // Short ETH market: supply USDC collateral, borrow WETH debt.
    Market internal market;
    // Long ETH market: the reversed live key, routable with no registration step.
    Market internal longMarket;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        spoke = new MockAaveV4Spoke(oracle);
        spoke.registerReserve(WETH_RESERVE_ID, address(weth), hub, 0, 2_000 * USD_BASE, WETH_CF_BPS);
        spoke.registerReserve(USDC_RESERVE_ID, address(usdc), hub, 5, 1 * USD_BASE, USDC_CF_BPS);

        adapter = new AaveV4LendingAdapter(ISpoke(address(spoke)));

        market = _key(usdc, weth, USDC_RESERVE_ID, WETH_RESERVE_ID);
        longMarket = _key(weth, usdc, WETH_RESERVE_ID, USDC_RESERVE_ID);
    }

    /// @dev Aave v4 keys a market by per-Spoke reserve ids, carried as two words in `data`.
    function _key(MockERC20 collateral, MockERC20 debt, uint256 collateralReserveId, uint256 debtReserveId)
        internal
        pure
        returns (Market memory)
    {
        return Market({
            collateral: Currency.wrap(address(collateral)),
            debt: Currency.wrap(address(debt)),
            data: abi.encode(collateralReserveId, debtReserveId)
        });
    }

    // External calldata-decode helpers.

    function decodeSupply(bytes calldata d)
        external
        pure
        returns (uint256 reserveId, uint256 amount, address onBehalfOf)
    {
        (reserveId, amount, onBehalfOf) = abi.decode(d[4:], (uint256, uint256, address));
    }

    function decodeSetCollateral(bytes calldata d)
        external
        pure
        returns (uint256 reserveId, bool usingAsCollateral, address onBehalfOf)
    {
        (reserveId, usingAsCollateral, onBehalfOf) = abi.decode(d[4:], (uint256, bool, address));
    }

    function decodeWithdraw(bytes calldata d)
        external
        pure
        returns (uint256 reserveId, uint256 amount, address onBehalfOf)
    {
        (reserveId, amount, onBehalfOf) = abi.decode(d[4:], (uint256, uint256, address));
    }

    function decodeBorrow(bytes calldata d)
        external
        pure
        returns (uint256 reserveId, uint256 amount, address onBehalfOf)
    {
        (reserveId, amount, onBehalfOf) = abi.decode(d[4:], (uint256, uint256, address));
    }

    function decodeRepay(bytes calldata d)
        external
        pure
        returns (uint256 reserveId, uint256 amount, address onBehalfOf)
    {
        (reserveId, amount, onBehalfOf) = abi.decode(d[4:], (uint256, uint256, address));
    }

    // -------------------------------------------------------------------------
    // lendingProtocol
    // -------------------------------------------------------------------------

    function testFuzz_lendingProtocol_isSpoke(address) public view {
        assertEq(adapter.lendingProtocol(), address(spoke));
    }

    // -------------------------------------------------------------------------
    // encodeSupplyCollateral + encodeEnableCollateral
    // -------------------------------------------------------------------------

    function testFuzz_encodeSupplyAndEnableCollateral(address account, uint256 amount) public view {
        (address supplyTarget, uint256 supplyValue, bytes memory supplyData) =
            adapter.encodeSupplyCollateral(account, market, amount);
        assertEq(supplyTarget, address(spoke), "supply target must be spoke");
        assertEq(supplyValue, 0, "supply value must be 0");
        assertEq(bytes4(supplyData), ISpoke.supply.selector, "supply is a plain call");
        (uint256 supplyId, uint256 decodedAmount, address supplyOnBehalf) = this.decodeSupply(supplyData);
        assertEq(supplyId, USDC_RESERVE_ID, "supply reserveId must be USDC");
        assertEq(decodedAmount, amount, "supply amount mismatch");
        assertEq(supplyOnBehalf, account, "supply onBehalfOf must be account");

        (address enableTarget, uint256 enableValue, bytes memory enableData) =
            adapter.encodeEnableCollateral(account, market);
        assertEq(enableTarget, address(spoke), "enable target must be spoke");
        assertEq(enableValue, 0, "enable value must be 0");
        assertEq(bytes4(enableData), ISpoke.setUsingAsCollateral.selector, "enable is setUsingAsCollateral");
        (uint256 collId, bool flag, address collOnBehalf) = this.decodeSetCollateral(enableData);
        assertEq(collId, USDC_RESERVE_ID, "setCollateral reserveId must be USDC");
        assertTrue(flag, "collateral flag must be true");
        assertEq(collOnBehalf, account, "setCollateral onBehalfOf must be account");
    }

    // -------------------------------------------------------------------------
    // encodeWithdrawCollateral
    // -------------------------------------------------------------------------

    function testFuzz_encodeWithdrawCollateral_shape(address account, uint256 amount, address receiver) public {
        vm.prank(account);
        (address target, uint256 value, bytes memory data) =
            adapter.encodeWithdrawCollateral(account, market, amount, receiver);
        assertEq(target, address(spoke), "target must be spoke");
        assertEq(value, 0, "value must be 0");
        assertEq(bytes4(data), ISpoke.withdraw.selector, "wrong selector");
        (uint256 reserveId, uint256 decodedAmount, address onBehalfOf) = this.decodeWithdraw(data);
        assertEq(reserveId, USDC_RESERVE_ID, "reserveId must be USDC (collateral)");
        assertEq(decodedAmount, amount, "amount mismatch");
        assertEq(onBehalfOf, account, "onBehalfOf must be account");
    }

    // -------------------------------------------------------------------------
    // encodeBorrow
    // -------------------------------------------------------------------------

    function testFuzz_encodeBorrow_shape(address account, uint256 amount) public view {
        (address target, uint256 value, bytes memory data) = adapter.encodeBorrow(account, market, amount);
        assertEq(target, address(spoke), "target must be spoke");
        assertEq(value, 0, "value must be 0");
        assertEq(bytes4(data), ISpoke.borrow.selector, "wrong selector");
        (uint256 reserveId, uint256 decodedAmount, address onBehalfOf) = this.decodeBorrow(data);
        assertEq(reserveId, WETH_RESERVE_ID, "reserveId must be WETH (debt)");
        assertEq(decodedAmount, amount, "amount mismatch");
        assertEq(onBehalfOf, account, "onBehalfOf must be account");
    }

    // -------------------------------------------------------------------------
    // encodeRepay
    // -------------------------------------------------------------------------

    function testFuzz_encodeRepay_shape(address account, uint256 amount) public {
        spoke.seedDebt(WETH_RESERVE_ID, account, 1); // the encoder no-ops without live debt
        (address target, uint256 value, bytes memory data) = adapter.encodeRepay(account, market, amount);
        assertEq(target, address(spoke), "target must be spoke");
        assertEq(value, 0, "value must be 0");
        assertEq(bytes4(data), ISpoke.repay.selector, "wrong selector");
        (uint256 reserveId, uint256 decodedAmount, address onBehalfOf) = this.decodeRepay(data);
        assertEq(reserveId, WETH_RESERVE_ID, "reserveId must be WETH (debt)");
        assertEq(decodedAmount, amount, "amount mismatch (Spoke caps max to owed)");
        assertEq(onBehalfOf, account, "onBehalfOf must be account");
    }

    function testFuzz_encodeRepay_zeroDebt_encodesNoOp(address account, uint256 amount) public view {
        // no debt seeded: any requested amount encodes the empty skip signal
        (address target, uint256 value, bytes memory data) = adapter.encodeRepay(account, market, amount);
        assertEq(target, address(spoke), "target must be spoke");
        assertEq(value, 0, "value must be 0");
        assertEq(data.length, 0, "debt-free repay must be an empty no-op");
    }

    // -------------------------------------------------------------------------
    // positionOf: seeded via mock helpers
    // -------------------------------------------------------------------------

    function testFuzz_positionOf_reflectsSeededAmounts(address account, uint128 collAmt, uint128 debtAmt) public {
        spoke.seedSupplied(USDC_RESERVE_ID, account, collAmt);
        spoke.seedDebt(WETH_RESERVE_ID, account, debtAmt);
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
    // currentLtvWad: formula verification at Value/RAY scales
    //
    // MockAaveV4Spoke.getUserAccountData():
    //   totalCollateralValue += supplied * priceBase / 10^decimals   (USD * 1e8)
    //   totalDebtValueRay    += (debt * priceBase / 10^decimals) * 1e27
    //
    // The adapter computes:
    //   LTV = mulDiv(totalDebtValueRay, WAD, totalCollateralValue * RAY)
    // -------------------------------------------------------------------------

    /// Zero debt always yields zero LTV.
    function testFuzz_currentLtvWad_zeroDebt(address account, uint64 collAmt) public {
        if (collAmt != 0) spoke.seedSupplied(USDC_RESERVE_ID, account, collAmt);
        assertEq(Ltv.unwrap(adapter.currentLtvWad(account, market)), 0);
    }

    /// Debt with no collateral yields max LTV.
    /// debtAmt bounded below MIN_WETH_FOR_NONZERO_USD to avoid integer truncation
    /// in the mock's USD-base calculation (debtAmt * 2000e8 / 1e18 must be > 0).
    function testFuzz_currentLtvWad_debtNoCollateral(address account, uint256 debtAmt) public {
        debtAmt = bound(debtAmt, MIN_WETH_FOR_NONZERO_USD, type(uint64).max);
        spoke.seedDebt(WETH_RESERVE_ID, account, debtAmt);
        assertEq(Ltv.unwrap(adapter.currentLtvWad(account, market)), type(uint256).max);
    }

    /// currentLtvWad matches the hand-computed Value/RAY formula.
    ///
    /// Amounts are bounded to uint64 to keep the intermediate products from
    /// overflowing the mock's internal arithmetic. Both amounts must produce
    /// non-zero USD-base values to exercise the non-trivial ratio branch.
    function testFuzz_currentLtvWad_matchesFormula(address account, uint64 collAmt, uint64 debtAmt) public {
        // Need both legs to be non-zero and the USD-base computation to be non-zero.
        // USDC @ 6 dec / price 1e8: any collAmt > 0 gives collateralValue > 0.
        // WETH @ 18 dec / price 2000e8: need debtAmt >= MIN_WETH_FOR_NONZERO_USD.
        collAmt = uint64(bound(uint256(collAmt), 1, type(uint64).max));
        debtAmt = uint64(bound(uint256(debtAmt), MIN_WETH_FOR_NONZERO_USD, type(uint64).max));

        spoke.seedSupplied(USDC_RESERVE_ID, account, collAmt);
        spoke.seedDebt(WETH_RESERVE_ID, account, debtAmt);

        ISpoke.UserAccountData memory data = spoke.getUserAccountData(account);

        // LTV = mulDiv(totalDebtValueRay, WAD, totalCollateralValue * RAY)
        uint256 expected = Math.mulDiv(data.totalDebtValueRay, WAD, data.totalCollateralValue * RAY);
        assertEq(Ltv.unwrap(adapter.currentLtvWad(account, market)), expected, "ltv formula mismatch");
    }

    // -------------------------------------------------------------------------
    // market key validation (per call: there is no registration step)
    // -------------------------------------------------------------------------

    /// @dev `data` must be exactly two words. Any other length reverts with the length seen on both the
    ///      encode and read paths, and the probe is false, rather than decoding a default market.
    function testFuzz_market_revertsOnWrongLengthData(address account, bytes memory data) public {
        if (data.length == 64) data = bytes.concat(data, hex"00");
        Market memory keyed = Market({collateral: market.collateral, debt: market.debt, data: data});

        assertFalse(adapter.isSupportedMarket(keyed), "wrong-length data is never supported");

        bytes memory expected = abi.encodeWithSelector(ILendingAdapter.InvalidMarketData.selector, data.length);
        vm.expectRevert(expected);
        adapter.encodeSupplyCollateral(account, keyed, 1e6);
        vm.expectRevert(expected);
        adapter.positionOf(account, keyed);
    }

    /// @dev A reserve id the Spoke has not configured, on either side, names a market the venue does
    ///      not have: the probe is false and the encode and read paths revert MarketNotSupported.
    function testFuzz_market_revertsOnUnconfiguredReserveId(address account, uint256 reserveId) public {
        vm.assume(reserveId != WETH_RESERVE_ID && reserveId != USDC_RESERVE_ID);
        Market memory badDebt = _key(usdc, weth, USDC_RESERVE_ID, reserveId);
        Market memory badCollateral = _key(usdc, weth, reserveId, WETH_RESERVE_ID);

        assertFalse(adapter.isSupportedMarket(badDebt), "unconfigured debt id is never supported");
        assertFalse(adapter.isSupportedMarket(badCollateral), "unconfigured collateral id is never supported");

        bytes memory expected =
            abi.encodeWithSelector(ILendingAdapter.MarketNotSupported.selector, market.collateral, market.debt);
        vm.expectRevert(expected);
        adapter.encodeSupplyCollateral(account, badDebt, 1e6);
        vm.expectRevert(expected);
        adapter.encodeBorrow(account, badCollateral, 1e18);
        vm.expectRevert(expected);
        adapter.positionOf(account, badDebt);
        vm.expectRevert(expected);
        adapter.positionOf(account, badCollateral);
    }

    /// @dev A configured reserve id paired with the other side's currency is a mis-typed key, not a
    ///      missing market: the revert names the reserve, its actual underlying, and the currency the
    ///      key claimed for it.
    function testFuzz_market_revertsOnReserveMismatch(address account, uint256 amount) public {
        // the WETH reserve id on the USDC collateral side
        Market memory collateralMismatch = _key(usdc, weth, WETH_RESERVE_ID, WETH_RESERVE_ID);
        assertFalse(adapter.isSupportedMarket(collateralMismatch), "collateral mismatch is never supported");
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4LendingAdapter.ReserveMismatch.selector, WETH_RESERVE_ID, address(weth), address(usdc)
            )
        );
        adapter.encodeSupplyCollateral(account, collateralMismatch, amount);

        // the USDC reserve id on the WETH debt side
        Market memory debtMismatch = _key(usdc, weth, USDC_RESERVE_ID, USDC_RESERVE_ID);
        assertFalse(adapter.isSupportedMarket(debtMismatch), "debt mismatch is never supported");
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4LendingAdapter.ReserveMismatch.selector, USDC_RESERVE_ID, address(usdc), address(weth)
            )
        );
        adapter.encodeBorrow(account, debtMismatch, amount);
    }

    /// @dev Permissionless selection: the reversed live key (WETH collateral, USDC debt) routes with
    ///      no registration step and encodes against its own reserve ids.
    function testFuzz_longMarket_routesWithoutRegistration(address account, uint256 amount) public view {
        assertTrue(adapter.isSupportedMarket(longMarket), "long key is live");

        (address target,, bytes memory supplyData) = adapter.encodeSupplyCollateral(account, longMarket, amount);
        assertEq(target, address(spoke), "target must be spoke");
        (uint256 supplyId, uint256 decodedAmount, address onBehalfOf) = this.decodeSupply(supplyData);
        assertEq(supplyId, WETH_RESERVE_ID, "long key supplies the WETH reserve");
        assertEq(decodedAmount, amount, "amount mismatch");
        assertEq(onBehalfOf, account, "onBehalfOf must be account");

        (,, bytes memory borrowData) = adapter.encodeBorrow(account, longMarket, amount);
        (uint256 borrowId, uint256 borrowAmount,) = this.decodeBorrow(borrowData);
        assertEq(borrowId, USDC_RESERVE_ID, "long key borrows the USDC reserve");
        assertEq(borrowAmount, amount, "amount mismatch");

        assertEq(Ltv.unwrap(adapter.maxLtvWad(longMarket)), uint256(WETH_CF_BPS) * WAD / 1e4, "maxLtv reads WETH");
    }
}
