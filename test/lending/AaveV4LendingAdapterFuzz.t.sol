// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {AaveV4LendingAdapter} from "../../src/AaveV4LendingAdapter.sol";
import {ISpoke} from "../../src/interfaces/external/aave-v4/ISpoke.sol";
import {Market} from "../../src/types/Market.sol";
import {NotOwner, NotPendingOwner} from "../../src/types/Owner.sol";
import {Ltv} from "../../src/types/Ltv.sol";
import {MockAaveV4Spoke} from "../mocks/MockAaveV4Spoke.sol";

/// @notice Fuzz tests for AaveV4LendingAdapter — encode* output shape, multicall
///         wrapping for supplyCollateral, positionOf seeding, currentLtvWad formula
///         at real Value/RAY scales, and access-control gating.
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

    address internal gov = makeAddr("gov");
    address internal hub = makeAddr("hub");
    address internal oracle = makeAddr("oracle");

    MockERC20 internal usdc;
    MockERC20 internal weth;
    Market internal market;
    Market internal longMarket;
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
        unroutedMarket = Market({collateral: Currency.wrap(address(usdc)), debt: Currency.wrap(address(usdc))});

        vm.startPrank(gov);
        adapter.setMarket(market.collateral, market.debt, USDC_RESERVE_ID, WETH_RESERVE_ID, true);
        adapter.setMarket(longMarket.collateral, longMarket.debt, WETH_RESERVE_ID, USDC_RESERVE_ID, true);
        vm.stopPrank();
    }

    // External calldata-decode helpers.
    function decodeMulticall(bytes calldata d) external pure returns (bytes[] memory calls) {
        calls = abi.decode(d[4:], (bytes[]));
    }

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
    // encodeSupplyCollateral — multicall wrapping
    // -------------------------------------------------------------------------

    function testFuzz_encodeSupplyCollateral_multicallWrapsSupplyAndSetCollateral(address account, uint256 amount)
        public
        view
    {
        (address target, uint256 value, bytes memory data) = adapter.encodeSupplyCollateral(account, market, amount);
        assertEq(target, address(spoke), "target must be spoke");
        assertEq(value, 0, "value must be 0");
        assertEq(bytes4(data), ISpoke.multicall.selector, "outer selector must be multicall");

        bytes[] memory calls = this.decodeMulticall(data);
        assertEq(calls.length, 2, "must batch supply + setUsingAsCollateral");

        assertEq(bytes4(calls[0]), ISpoke.supply.selector, "first call must be supply");
        (uint256 supplyId, uint256 decodedAmount, address supplyOnBehalf) = this.decodeSupply(calls[0]);
        assertEq(supplyId, USDC_RESERVE_ID, "supply reserveId must be USDC");
        assertEq(decodedAmount, amount, "supply amount mismatch");
        assertEq(supplyOnBehalf, account, "supply onBehalfOf must be account");

        assertEq(bytes4(calls[1]), ISpoke.setUsingAsCollateral.selector, "second call must be setUsingAsCollateral");
        (uint256 collId, bool flag, address collOnBehalf) = this.decodeSetCollateral(calls[1]);
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

    function testFuzz_encodeRepay_shape(address account, uint256 amount) public view {
        (address target, uint256 value, bytes memory data) = adapter.encodeRepay(account, market, amount);
        assertEq(target, address(spoke), "target must be spoke");
        assertEq(value, 0, "value must be 0");
        assertEq(bytes4(data), ISpoke.repay.selector, "wrong selector");
        (uint256 reserveId, uint256 decodedAmount, address onBehalfOf) = this.decodeRepay(data);
        assertEq(reserveId, WETH_RESERVE_ID, "reserveId must be WETH (debt)");
        assertEq(decodedAmount, amount, "amount mismatch (Spoke caps max to owed)");
        assertEq(onBehalfOf, account, "onBehalfOf must be account");
    }

    // -------------------------------------------------------------------------
    // positionOf — seeded via mock helpers
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
    // currentLtvWad — formula verification at Value/RAY scales
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
    // setMarket access-control gating
    // -------------------------------------------------------------------------

    /// setMarket reverts NotOwner for any caller that is not the owner.
    function testFuzz_setMarket_revertsForNonOwner(address caller) public {
        vm.assume(caller != gov);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(NotOwner.selector, caller));
        adapter.setMarket(market.collateral, market.debt, USDC_RESERVE_ID, WETH_RESERVE_ID, true);
    }

    /// setMarket reverts ReserveMismatch when the collateral reserve underlying
    /// does not match the supplied collateral currency.
    function testFuzz_setMarket_revertsOnUnderlyingMismatch(uint256) public {
        // Use WETH_RESERVE_ID as the collateral reserve, but pass USDC as collateral currency.
        // The Spoke reports WETH as underlying for WETH_RESERVE_ID, not USDC => ReserveMismatch.
        vm.prank(gov);
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4LendingAdapter.ReserveMismatch.selector,
                WETH_RESERVE_ID,
                address(weth), // actual underlying of WETH_RESERVE_ID
                address(usdc) // expected (we passed USDC as collateral)
            )
        );
        adapter.setMarket(market.collateral, market.debt, WETH_RESERVE_ID, WETH_RESERVE_ID, true);
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
