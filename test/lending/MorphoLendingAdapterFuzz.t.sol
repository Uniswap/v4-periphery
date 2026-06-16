// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMorpho, IMorphoBase, MarketParams, Id, Position} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {MorphoLendingAdapter} from "../../src/MorphoLendingAdapter.sol";
import {Market} from "../../src/types/Market.sol";
import {MarketNotSupported} from "../../src/types/MarketRegistry.sol";
import {NotOwner, NotPendingOwner} from "../../src/types/Owner.sol";
import {Ltv} from "../../src/types/Ltv.sol";
import {MockMorpho} from "../mocks/MockMorpho.sol";

/// @notice Fuzz tests for MorphoLendingAdapter — encode* output shape, maxLtvWad,
///         isSupportedMarket, and access-control gating.
///
///         positionOf and currentLtvWad are omitted here: both call
///         MorphoBalancesLib.expectedBorrowAssets, which issues an extSloads call
///         not supported by MockMorpho. Those paths are exercised by the fork tests
///         in test/fork/MorphoLendingAdapter.fork.t.sol.
contract MorphoLendingAdapterFuzzTest is Test {
    using MarketParamsLib for MarketParams;

    MockMorpho internal morpho;
    MorphoLendingAdapter internal adapter;

    address internal gov = makeAddr("gov");
    address internal collateralToken = makeAddr("collateral");
    address internal debtToken = makeAddr("debt");

    MarketParams internal marketParams;
    Market internal market;

    function setUp() public {
        morpho = new MockMorpho();
        adapter = new MorphoLendingAdapter(IMorpho(address(morpho)), gov);

        marketParams = MarketParams({
            loanToken: debtToken,
            collateralToken: collateralToken,
            oracle: makeAddr("oracle"),
            irm: makeAddr("irm"),
            lltv: 0.86e18
        });
        market = Market({collateral: Currency.wrap(collateralToken), debt: Currency.wrap(debtToken)});
    }

    function _register() internal {
        morpho.setMarketParams(marketParams);
        vm.prank(gov);
        adapter.setMarket(marketParams);
    }

    // External calldata-decode helpers.
    function decodeSupplyCollateral(bytes calldata d)
        external
        pure
        returns (uint256 amount, address onBehalf, uint256 innerDataLen)
    {
        MarketParams memory mp;
        bytes memory inner;
        (mp, amount, onBehalf, inner) = abi.decode(d[4:], (MarketParams, uint256, address, bytes));
        innerDataLen = inner.length;
    }

    function decodeWithdrawCollateral(bytes calldata d)
        external
        pure
        returns (uint256 amount, address onBehalf, address receiver)
    {
        MarketParams memory mp;
        (mp, amount, onBehalf, receiver) = abi.decode(d[4:], (MarketParams, uint256, address, address));
    }

    function decodeBorrow(bytes calldata d)
        external
        pure
        returns (uint256 assets, uint256 shares, address onBehalf, address borrowReceiver)
    {
        MarketParams memory mp;
        (mp, assets, shares, onBehalf, borrowReceiver) =
            abi.decode(d[4:], (MarketParams, uint256, uint256, address, address));
    }

    function decodeRepay(bytes calldata d) external pure returns (uint256 assets, uint256 shares, address onBehalf) {
        MarketParams memory mp;
        bytes memory inner;
        (mp, assets, shares, onBehalf, inner) = abi.decode(d[4:], (MarketParams, uint256, uint256, address, bytes));
    }

    // -------------------------------------------------------------------------
    // lendingProtocol
    // -------------------------------------------------------------------------

    function testFuzz_lendingProtocol_isMorpho(address) public view {
        assertEq(adapter.lendingProtocol(), address(morpho));
    }

    // -------------------------------------------------------------------------
    // encodeSupplyCollateral
    // -------------------------------------------------------------------------

    function testFuzz_encodeSupplyCollateral_shape(address account, uint256 amount) public {
        _register();
        (address target, uint256 value, bytes memory data) = adapter.encodeSupplyCollateral(account, market, amount);
        assertEq(target, address(morpho), "target must be morpho");
        assertEq(value, 0, "value must be 0");
        assertEq(bytes4(data), IMorphoBase.supplyCollateral.selector, "wrong selector");
        (uint256 decodedAmount, address onBehalf, uint256 innerDataLen) = this.decodeSupplyCollateral(data);
        assertEq(decodedAmount, amount, "amount mismatch");
        assertEq(onBehalf, account, "onBehalf must be account");
        assertEq(innerDataLen, 0, "callback data must be empty");
    }

    // -------------------------------------------------------------------------
    // encodeWithdrawCollateral
    // -------------------------------------------------------------------------

    function testFuzz_encodeWithdrawCollateral_shape(address account, uint256 amount, address receiver) public {
        _register();
        (address target, uint256 value, bytes memory data) =
            adapter.encodeWithdrawCollateral(account, market, amount, receiver);
        assertEq(target, address(morpho), "target must be morpho");
        assertEq(value, 0, "value must be 0");
        assertEq(bytes4(data), IMorphoBase.withdrawCollateral.selector, "wrong selector");
        (uint256 decodedAmount, address onBehalf, address decodedReceiver) = this.decodeWithdrawCollateral(data);
        assertEq(decodedAmount, amount, "amount mismatch");
        assertEq(onBehalf, account, "onBehalf must be account");
        assertEq(decodedReceiver, receiver, "receiver mismatch");
    }

    // -------------------------------------------------------------------------
    // encodeBorrow
    // -------------------------------------------------------------------------

    function testFuzz_encodeBorrow_shape(address account, uint256 amount) public {
        _register();
        (address target, uint256 value, bytes memory data) = adapter.encodeBorrow(account, market, amount);
        assertEq(target, address(morpho), "target must be morpho");
        assertEq(value, 0, "value must be 0");
        assertEq(bytes4(data), IMorphoBase.borrow.selector, "wrong selector");
        (uint256 assets, uint256 shares, address onBehalf, address borrowReceiver) = this.decodeBorrow(data);
        assertEq(assets, amount, "assets must match amount");
        assertEq(shares, 0, "shares must be 0 (asset-denominated)");
        assertEq(onBehalf, account, "onBehalf must be account");
        assertEq(borrowReceiver, account, "receiver must be account");
    }

    // -------------------------------------------------------------------------
    // encodeRepay (partial)
    // -------------------------------------------------------------------------

    function testFuzz_encodeRepay_partial_assetDenominated(address account, uint256 amount) public {
        _register();
        // Avoid the max-uint share-based path.
        amount = bound(amount, 0, type(uint256).max - 1);
        (address target, uint256 value, bytes memory data) = adapter.encodeRepay(account, market, amount);
        assertEq(target, address(morpho), "target must be morpho");
        assertEq(value, 0, "value must be 0");
        assertEq(bytes4(data), IMorphoBase.repay.selector, "wrong selector");
        (uint256 assets, uint256 shares, address onBehalf) = this.decodeRepay(data);
        assertEq(assets, amount, "assets must match");
        assertEq(shares, 0, "partial repay must use assets not shares");
        assertEq(onBehalf, account, "onBehalf must be account");
    }

    /// encodeRepay(max) uses shares-based full repay: assets == 0, shares == borrowShares.
    function testFuzz_encodeRepay_max_usesShares(address account, uint128 borrowShares) public {
        _register();
        Id id = marketParams.id();
        morpho.setPosition(id, account, Position({supplyShares: 0, borrowShares: borrowShares, collateral: 0}));
        (,, bytes memory data) = adapter.encodeRepay(account, market, type(uint256).max);
        (uint256 assets, uint256 shares, address onBehalf) = this.decodeRepay(data);
        assertEq(assets, 0, "full repay must have assets == 0");
        assertEq(shares, uint256(borrowShares), "shares must match position borrowShares");
        assertEq(onBehalf, account, "onBehalf must be account");
    }

    // -------------------------------------------------------------------------
    // maxLtvWad — reads lltv from registered MarketParams
    // -------------------------------------------------------------------------

    /// maxLtvWad returns the registered lltv, wrapped as an Ltv.
    function testFuzz_maxLtvWad_returnsLltv(uint256 lltv) public {
        MarketParams memory mp = MarketParams({
            loanToken: debtToken,
            collateralToken: collateralToken,
            oracle: makeAddr("oracle"),
            irm: makeAddr("irm"),
            lltv: lltv
        });
        morpho.setMarketParams(mp);
        vm.prank(gov);
        adapter.setMarket(mp);
        assertEq(Ltv.unwrap(adapter.maxLtvWad(market)), lltv, "maxLtvWad must match lltv");
    }

    // -------------------------------------------------------------------------
    // isSupportedMarket
    // -------------------------------------------------------------------------

    /// isSupportedMarket is true for the registered pair and false for any other.
    function testFuzz_isSupportedMarket_trueForRegistered(address otherColl, address otherDebt) public {
        vm.assume(otherColl != collateralToken || otherDebt != debtToken);
        _register();
        assertTrue(adapter.isSupportedMarket(market), "registered market must be supported");
        Market memory other = Market({collateral: Currency.wrap(otherColl), debt: Currency.wrap(otherDebt)});
        assertFalse(adapter.isSupportedMarket(other), "unregistered market must not be supported");
    }

    // -------------------------------------------------------------------------
    // setMarket access control
    // -------------------------------------------------------------------------

    /// setMarket reverts NotOwner for any caller that is not the owner.
    function testFuzz_setMarket_revertsForNonOwner(address caller) public {
        vm.assume(caller != gov);
        morpho.setMarketParams(marketParams);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(NotOwner.selector, caller));
        adapter.setMarket(marketParams);
    }

    // -------------------------------------------------------------------------
    // transferOwnership / acceptOwnership access control
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

    // -------------------------------------------------------------------------
    // Unsupported market reverts
    // -------------------------------------------------------------------------

    /// Every encode* reverts MarketNotSupported for an unregistered pair.
    function testFuzz_unregisteredMarket_encodingReverts(address account, uint256 amount) public {
        Market memory bad = Market({collateral: Currency.wrap(makeAddr("x")), debt: Currency.wrap(makeAddr("y"))});
        vm.expectRevert(abi.encodeWithSelector(MarketNotSupported.selector, bad.collateral, bad.debt));
        adapter.encodeSupplyCollateral(account, bad, amount);
    }
}
