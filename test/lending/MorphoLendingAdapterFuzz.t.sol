// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {
    IMorpho,
    IMorphoBase,
    MarketParams,
    Id,
    Position,
    Market as MorphoMarket
} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {MorphoLendingAdapter} from "../../src/MorphoLendingAdapter.sol";
import {ILendingAdapter} from "../../src/interfaces/ILendingAdapter.sol";
import {Market} from "../../src/types/Market.sol";
import {Ltv} from "../../src/types/Ltv.sol";
import {MockMorpho} from "../mocks/MockMorpho.sol";

/// @notice Fuzz tests for MorphoLendingAdapter: encode* output shape, the repay clamps, maxLtvWad,
///         isSupportedMarket, and per-call key validation (`InvalidMarketData` for wrong-shape data,
///         `MarketNotSupported` for a key Morpho has not created, and every created key routing).
///
///         currentLtvWad and describePosition are omitted here: both price collateral through the
///         market oracle, which MockMorpho does not model. Those paths are exercised by the fork tests
///         in test/fork/MorphoLendingAdapter.fork.t.sol.
contract MorphoLendingAdapterFuzzTest is Test {
    using MarketParamsLib for MarketParams;

    uint256 internal constant MARKET_DATA_LENGTH = 96;

    MockMorpho internal morpho;
    MorphoLendingAdapter internal adapter;

    address internal collateralToken = makeAddr("collateral");
    address internal debtToken = makeAddr("debt");

    MarketParams internal marketParams;
    Market internal market;

    function setUp() public {
        morpho = new MockMorpho();
        adapter = new MorphoLendingAdapter(IMorpho(address(morpho)));

        marketParams = MarketParams({
            loanToken: debtToken,
            collateralToken: collateralToken,
            oracle: makeAddr("oracle"),
            irm: makeAddr("irm"),
            lltv: 0.86e18
        });
        market = _key(marketParams);
    }

    /// @dev The adapter's market key: the pair plus `abi.encode(oracle, irm, lltv)`.
    function _key(MarketParams memory mp) internal pure returns (Market memory) {
        return Market({
            collateral: Currency.wrap(mp.collateralToken),
            debt: Currency.wrap(mp.loanToken),
            data: abi.encode(mp.oracle, mp.irm, mp.lltv)
        });
    }

    /// @dev Makes the fixture market exist on Morpho; there is no adapter-side registration.
    function _create() internal {
        morpho.setMarketParams(marketParams);
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
        returns (MarketParams memory mp, uint256 assets, uint256 shares, address onBehalf, address borrowReceiver)
    {
        (
            mp, assets, shares, onBehalf, borrowReceiver
        ) = abi.decode(d[4:], (MarketParams, uint256, uint256, address, address));
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
        _create();
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
        _create();
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
        _create();
        (address target, uint256 value, bytes memory data) = adapter.encodeBorrow(account, market, amount);
        assertEq(target, address(morpho), "target must be morpho");
        assertEq(value, 0, "value must be 0");
        assertEq(bytes4(data), IMorphoBase.borrow.selector, "wrong selector");
        (, uint256 assets, uint256 shares, address onBehalf, address borrowReceiver) = this.decodeBorrow(data);
        assertEq(assets, amount, "assets must match amount");
        assertEq(shares, 0, "shares must be 0 (asset-denominated)");
        assertEq(onBehalf, account, "onBehalf must be account");
        assertEq(borrowReceiver, account, "receiver must be account");
    }

    // -------------------------------------------------------------------------
    // encodeRepay (partial)
    // -------------------------------------------------------------------------

    function testFuzz_encodeRepay_partial_assetDenominated(address account, uint256 amount) public {
        _create();
        // Seed a large reported debt with accrual skipped (lastUpdate == block.timestamp), then bound the
        // request strictly below it so it is a genuine partial that stays asset-denominated. A request at
        // or above the reported debt clamps to the share path (covered in the unit boundary tests).
        Id id = marketParams.id();
        morpho.setPosition(id, account, Position({supplyShares: 0, borrowShares: 1e30, collateral: 0}));
        morpho.setMarketState(
            id,
            MorphoMarket({
                totalSupplyAssets: 0,
                totalSupplyShares: 0,
                totalBorrowAssets: 1e30,
                totalBorrowShares: 1e30,
                lastUpdate: uint128(block.timestamp),
                fee: 0
            })
        );
        (, uint256 reportedDebt) = adapter.positionOf(account, market);
        amount = bound(amount, 1, reportedDebt - 1);
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
        _create();
        // a debt-free position (zero shares) encodes a no-op instead, covered separately
        borrowShares = uint128(bound(borrowShares, 1, type(uint128).max));
        Id id = marketParams.id();
        morpho.setPosition(id, account, Position({supplyShares: 0, borrowShares: borrowShares, collateral: 0}));
        (,, bytes memory data) = adapter.encodeRepay(account, market, type(uint256).max);
        (uint256 assets, uint256 shares, address onBehalf) = this.decodeRepay(data);
        assertEq(assets, 0, "full repay must have assets == 0");
        assertEq(shares, uint256(borrowShares), "shares must match position borrowShares");
        assertEq(onBehalf, account, "onBehalf must be account");
    }

    /// A debt-free position encodes an empty no-op the account skips (Morpho rejects a (0, 0) repay).
    function testFuzz_encodeRepay_zeroDebt_encodesNoOp(address account, uint256 amount) public {
        _create();
        // no borrow position seeded for `account`: borrowShares == 0
        (, uint256 value, bytes memory data) = adapter.encodeRepay(account, market, amount);
        assertEq(value, 0);
        assertEq(data.length, 0, "debt-free repay must be an empty no-op");
    }

    // -------------------------------------------------------------------------
    // maxLtvWad: reads lltv from the MarketParams the key names
    // -------------------------------------------------------------------------

    /// maxLtvWad returns the created market's lltv, wrapped as an Ltv.
    function testFuzz_maxLtvWad_returnsLltv(uint256 lltv) public {
        MarketParams memory mp = marketParams;
        mp.lltv = lltv;
        morpho.setMarketParams(mp);
        assertEq(Ltv.unwrap(adapter.maxLtvWad(_key(mp))), lltv, "maxLtvWad must match lltv");
    }

    // -------------------------------------------------------------------------
    // Key validation: any created market routes, nothing else does
    // -------------------------------------------------------------------------

    /// Whatever (oracle, irm, lltv) a market was created with, its key routes: the probe is true and
    /// every encode carries exactly those MarketParams. There is no allowlist to pass first.
    function testFuzz_createdKey_alwaysRoutes(address oracle, address irm, uint256 lltv, uint256 amount) public {
        MarketParams memory mp = marketParams;
        mp.oracle = oracle;
        mp.irm = irm;
        mp.lltv = lltv;
        morpho.setMarketParams(mp);
        Market memory key = _key(mp);

        assertTrue(adapter.isSupportedMarket(key), "created market must be routable");
        assertEq(Ltv.unwrap(adapter.maxLtvWad(key)), lltv, "maxLtvWad reads the created lltv");
        (address target,, bytes memory data) = adapter.encodeBorrow(address(this), key, amount);
        assertEq(target, address(morpho), "target must be morpho");
        (MarketParams memory encoded,,,,) = this.decodeBorrow(data);
        assertEq(encoded.oracle, oracle, "encoded oracle");
        assertEq(encoded.irm, irm, "encoded irm");
        assertEq(encoded.lltv, lltv, "encoded lltv");
        assertEq(encoded.loanToken, debtToken, "encoded loan token");
        assertEq(encoded.collateralToken, collateralToken, "encoded collateral token");
    }

    /// isSupportedMarket is true for the created key and false for the same data on any other pair.
    function testFuzz_isSupportedMarket_trueOnlyForCreatedPair(address otherColl, address otherDebt) public {
        vm.assume(otherColl != collateralToken || otherDebt != debtToken);
        _create();
        assertTrue(adapter.isSupportedMarket(market), "created market must be supported");
        Market memory other =
            Market({collateral: Currency.wrap(otherColl), debt: Currency.wrap(otherDebt), data: market.data});
        assertFalse(adapter.isSupportedMarket(other), "uncreated pair must not be supported");
    }

    /// isSupportedMarket is false for the created pair under any lltv Morpho has not created.
    function testFuzz_isSupportedMarket_falseForUncreatedLltv(uint256 lltv) public {
        vm.assume(lltv != marketParams.lltv);
        _create();
        MarketParams memory mp = marketParams;
        mp.lltv = lltv;
        assertFalse(adapter.isSupportedMarket(_key(mp)), "uncreated lltv must not be supported");
    }

    /// Any data length other than the canonical 96 bytes reverts InvalidMarketData(length) on encodes
    /// and reads alike, before the market lookup, and the probe reports it unroutable.
    function testFuzz_invalidMarketData_reverts(uint256 length, address account, uint256 amount) public {
        length = bound(length, 0, 4 * MARKET_DATA_LENGTH);
        vm.assume(length != MARKET_DATA_LENGTH);
        _create();
        Market memory bad = Market({collateral: market.collateral, debt: market.debt, data: new bytes(length)});
        bytes memory err = abi.encodeWithSelector(ILendingAdapter.InvalidMarketData.selector, length);

        assertFalse(adapter.isSupportedMarket(bad), "malformed key must not be supported");
        vm.expectRevert(err);
        adapter.encodeSupplyCollateral(account, bad, amount);
        vm.expectRevert(err);
        adapter.encodeBorrow(account, bad, amount);
        vm.expectRevert(err);
        adapter.positionOf(account, bad);
        vm.expectRevert(err);
        adapter.maxLtvWad(bad);
    }

    /// A well-formed key naming any (oracle, irm, lltv) Morpho has not created reverts MarketNotSupported
    /// on every encoder and read; the created market for the same pair is never used as a fallback.
    function testFuzz_uncreatedMarket_reverts(
        address oracle,
        address irm,
        uint256 lltv,
        address account,
        uint256 amount
    ) public {
        vm.assume(oracle != marketParams.oracle || irm != marketParams.irm || lltv != marketParams.lltv);
        _create();
        MarketParams memory mp = marketParams;
        mp.oracle = oracle;
        mp.irm = irm;
        mp.lltv = lltv;
        Market memory bad = _key(mp);
        bytes memory err = abi.encodeWithSelector(ILendingAdapter.MarketNotSupported.selector, bad.collateral, bad.debt);

        assertFalse(adapter.isSupportedMarket(bad), "uncreated market must not be supported");
        vm.expectRevert(err);
        adapter.encodeSupplyCollateral(account, bad, amount);
        vm.expectRevert(err);
        adapter.encodeWithdrawCollateral(account, bad, amount, account);
        vm.expectRevert(err);
        adapter.encodeBorrow(account, bad, amount);
        vm.expectRevert(err);
        adapter.encodeRepay(account, bad, amount);
        vm.expectRevert(err);
        adapter.positionOf(account, bad);
        vm.expectRevert(err);
        adapter.maxLtvWad(bad);
    }
}
