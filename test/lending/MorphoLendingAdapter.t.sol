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
import {PositionAmountResolver} from "../../src/base/PositionAmountResolver.sol";
import {Market} from "../../src/types/Market.sol";
import {Ltv} from "../../src/types/Ltv.sol";
import {MockMorpho} from "../mocks/MockMorpho.sol";

contract MorphoLendingAdapterTest is Test {
    using MarketParamsLib for MarketParams;

    MockMorpho internal morpho;
    MorphoLendingAdapter internal adapter;

    address internal account = makeAddr("account");

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

    /// @dev The adapter's market key: the pair plus `abi.encode(oracle, irm, lltv)`, which together are
    ///      the full Morpho `MarketParams`. The adapter rebuilds the params from the key on every call.
    function _key(MarketParams memory mp) internal pure returns (Market memory) {
        return Market({
            collateral: Currency.wrap(mp.collateralToken),
            debt: Currency.wrap(mp.loanToken),
            data: abi.encode(mp.oracle, mp.irm, mp.lltv)
        });
    }

    /// @dev A key for the same pair whose `lltv` names a market Morpho has not created.
    function _uncreatedKey() internal view returns (Market memory) {
        MarketParams memory other = marketParams;
        other.lltv = 0.5e18;
        return _key(other);
    }

    /// @dev A key for the created pair whose `data` is not the canonical three words.
    function _malformedKey(uint256 length) internal view returns (Market memory) {
        return Market({collateral: market.collateral, debt: market.debt, data: new bytes(length)});
    }

    /// @dev Makes the market exist on Morpho. There is no adapter-side registration: any market Morpho
    ///      has created is routable by its key.
    function _create() internal {
        morpho.setMarketParams(marketParams);
    }

    /// @dev Seeds a borrow position plus 1:1 market totals with `lastUpdate == block.timestamp` so
    ///      accrual is skipped, making `expectedBorrowAssets` a deterministic function of the shares.
    function _seedBorrow(
        MarketParams memory mp,
        address who,
        uint128 borrowShares,
        uint128 totalBorrowAssets,
        uint128 totalBorrowShares
    ) internal {
        Id id = mp.id();
        morpho.setPosition(id, who, Position({supplyShares: 0, borrowShares: borrowShares, collateral: 0}));
        morpho.setMarketState(
            id,
            MorphoMarket({
                totalSupplyAssets: 0,
                totalSupplyShares: 0,
                totalBorrowAssets: totalBorrowAssets,
                totalBorrowShares: totalBorrowShares,
                lastUpdate: uint128(block.timestamp),
                fee: 0
            })
        );
    }

    // calldata decode helpers (slice the 4-byte selector, then abi.decode the args)
    function decodeSupply(bytes calldata d) external pure returns (uint256 amount, address onBehalf, uint256 dataLen) {
        MarketParams memory mp;
        bytes memory inner;
        (mp, amount, onBehalf, inner) = abi.decode(d[4:], (MarketParams, uint256, address, bytes));
        dataLen = inner.length;
    }

    function decodeSupplyParams(bytes calldata d) external pure returns (MarketParams memory mp) {
        (mp,,,) = abi.decode(d[4:], (MarketParams, uint256, address, bytes));
    }

    function decodeRepay(bytes calldata d) external pure returns (uint256 assets, uint256 shares, address onBehalf) {
        MarketParams memory mp;
        bytes memory inner;
        (mp, assets, shares, onBehalf, inner) = abi.decode(d[4:], (MarketParams, uint256, uint256, address, bytes));
    }

    /// @dev Asserts every validating entry point rejects `bad` with exactly `err`. `encodeEnableCollateral`
    ///      is excluded: it is a documented pure no-op on Morpho and decodes nothing.
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

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert(MorphoLendingAdapter.ZeroAddress.selector);
        new MorphoLendingAdapter(IMorpho(address(0)));
    }

    function test_lendingProtocol_returnsMorphoSingleton() public view {
        assertEq(adapter.lendingProtocol(), address(morpho));
    }

    // ---- key validation: the key must name a market Morpho has created ----

    function test_isSupportedMarket_trueForCreatedMarket() public {
        _create();
        assertTrue(adapter.isSupportedMarket(market));
    }

    function test_isSupportedMarket_falseWhenMarketNotCreated() public view {
        // morpho.idToMarketParams is unset, so the market does not exist on Morpho
        assertFalse(adapter.isSupportedMarket(market));
    }

    function test_isSupportedMarket_falseForUncreatedLltv() public {
        _create();
        assertFalse(adapter.isSupportedMarket(_uncreatedKey()));
    }

    /// @dev The probe never reverts: malformed data is simply not a routable key.
    function test_isSupportedMarket_falseForWrongLengthData() public {
        _create();
        assertFalse(adapter.isSupportedMarket(_malformedKey(0)));
        assertFalse(adapter.isSupportedMarket(_malformedKey(64)));
        assertFalse(adapter.isSupportedMarket(_malformedKey(128)));
    }

    function test_encodeSupplyCollateral_revertsOnShortMarketData() public {
        _create();
        vm.expectRevert(abi.encodeWithSelector(ILendingAdapter.InvalidMarketData.selector, 64));
        adapter.encodeSupplyCollateral(account, _malformedKey(64), 1e18);
    }

    function test_maxLtvWad_revertsOnLongMarketData() public {
        _create();
        vm.expectRevert(abi.encodeWithSelector(ILendingAdapter.InvalidMarketData.selector, 128));
        adapter.maxLtvWad(_malformedKey(128));
    }

    /// @dev The length check runs before the market lookup, so wrong-shape data is reported as such on
    ///      every entry point even though the pair itself is live.
    function test_invalidMarketData_revertsEverywhere() public {
        _create();
        _assertRevertsEverywhere(
            _malformedKey(64), abi.encodeWithSelector(ILendingAdapter.InvalidMarketData.selector, 64)
        );
    }

    function test_encodeBorrow_revertsWhenMarketNotSupported() public {
        vm.expectRevert(
            abi.encodeWithSelector(ILendingAdapter.MarketNotSupported.selector, market.collateral, market.debt)
        );
        adapter.encodeBorrow(account, market, 1e18);
    }

    /// @dev The adapter doubles as an IAmountResolver; the resolver read routes through the same key
    ///      validation as positionOf, so an uncreated market reverts rather than resolving zero.
    function test_resolveAmount_revertsWhenMarketNotSupported() public {
        bytes memory context = abi.encode(PositionAmountResolver.PositionAmount.DEBT, account, market);
        vm.expectRevert(
            abi.encodeWithSelector(ILendingAdapter.MarketNotSupported.selector, market.collateral, market.debt)
        );
        adapter.resolveAmount(context);
    }

    function test_resolveAmount_returnsLiveDebtForCreatedMarket() public {
        _create();
        _seedBorrow(marketParams, account, 100e18, 100e18, 100e18);
        (, uint256 reportedDebt) = adapter.positionOf(account, market);
        bytes memory context = abi.encode(PositionAmountResolver.PositionAmount.DEBT, account, market);
        assertEq(adapter.resolveAmount(context), reportedDebt, "resolver reads the same debt as positionOf");
    }

    /// @dev A key whose lltv names a market Morpho has not created reverts on every entry point. It
    ///      must never fall back to the created market for the same pair.
    function test_uncreatedMarket_revertsEverywhere() public {
        _create();
        Market memory bad = _uncreatedKey();
        _assertRevertsEverywhere(
            bad, abi.encodeWithSelector(ILendingAdapter.MarketNotSupported.selector, bad.collateral, bad.debt)
        );
    }

    /// @dev Market selection is permissionless: two Morpho markets for one pair (differing only in lltv)
    ///      are two keys, each resolving to its own MarketParams with no adapter-side registration.
    function test_multipleMarketsForSamePair_resolveIndependently() public {
        _create();
        MarketParams memory second = marketParams;
        second.lltv = 0.77e18;
        morpho.setMarketParams(second);
        Market memory secondKey = _key(second);

        assertTrue(adapter.isSupportedMarket(market), "first market routable");
        assertTrue(adapter.isSupportedMarket(secondKey), "second market routable");
        assertEq(Ltv.unwrap(adapter.maxLtvWad(market)), 0.86e18, "first market lltv");
        assertEq(Ltv.unwrap(adapter.maxLtvWad(secondKey)), 0.77e18, "second market lltv");

        // the encoded MarketParams carry each key's own lltv and hash to each market's own id
        (,, bytes memory firstData) = adapter.encodeSupplyCollateral(account, market, 1e18);
        (,, bytes memory secondData) = adapter.encodeSupplyCollateral(account, secondKey, 1e18);
        MarketParams memory firstParams = this.decodeSupplyParams(firstData);
        MarketParams memory secondParams = this.decodeSupplyParams(secondData);
        assertEq(firstParams.lltv, 0.86e18, "first encode carries first lltv");
        assertEq(secondParams.lltv, 0.77e18, "second encode carries second lltv");
        assertEq(Id.unwrap(firstParams.id()), Id.unwrap(marketParams.id()), "first encode targets first id");
        assertEq(Id.unwrap(secondParams.id()), Id.unwrap(second.id()), "second encode targets second id");

        // a borrow held in the second market is invisible through the first key
        _seedBorrow(second, account, 40e18, 40e18, 40e18);
        (, uint256 firstDebt) = adapter.positionOf(account, market);
        (, uint256 secondDebt) = adapter.positionOf(account, secondKey);
        assertEq(firstDebt, 0, "first market has no debt");
        // Morpho's share-to-asset conversion adds virtual shares, so the reported debt sits a hair
        // under the seeded 40e18; what matters is that it is the second market's debt, not the first's
        assertApproxEqAbs(secondDebt, 40e18, 1e7, "second market reports its own debt");
    }

    // ---- encoders ----

    function test_encodeSupplyCollateral_targetOnBehalfAndEmptyData() public {
        _create();
        (address target, uint256 value, bytes memory data) = adapter.encodeSupplyCollateral(account, market, 5e18);
        assertEq(target, address(morpho));
        assertEq(value, 0);
        assertEq(bytes4(data), IMorphoBase.supplyCollateral.selector);
        (uint256 amount, address onBehalf, uint256 dataLen) = this.decodeSupply(data);
        assertEq(amount, 5e18);
        assertEq(onBehalf, account); // the account is always the onBehalf
        assertEq(dataLen, 0); // empty data so no Morpho callback fires
    }

    /// @dev Morpho treats supplied collateral as collateral automatically, so the enable step is the
    ///      empty skip signal the account honours.
    function test_encodeEnableCollateral_encodesNoOp() public view {
        (address target, uint256 value, bytes memory data) = adapter.encodeEnableCollateral(account, market);
        assertEq(target, address(0));
        assertEq(value, 0);
        assertEq(data.length, 0);
    }

    function test_encodeRepay_max_usesSharesBasedFullRepay() public {
        _create();
        Id id = marketParams.id();
        morpho.setPosition(id, account, Position({supplyShares: 0, borrowShares: 77, collateral: 0}));
        (,, bytes memory data) = adapter.encodeRepay(account, market, type(uint256).max);
        assertEq(bytes4(data), IMorphoBase.repay.selector);
        (uint256 assets, uint256 shares, address onBehalf) = this.decodeRepay(data);
        assertEq(assets, 0);
        assertEq(shares, 77); // burns the account's full borrow share balance
        assertEq(onBehalf, account);
    }

    function test_encodeRepay_partialBelowDebt_usesAssets() public {
        _create();
        // reported debt ~100e18; a request well below it is a genuine partial and stays asset-denominated
        _seedBorrow(marketParams, account, 100e18, 100e18, 100e18);
        (,, bytes memory data) = adapter.encodeRepay(account, market, 9e18);
        (uint256 assets, uint256 shares,) = this.decodeRepay(data);
        assertEq(assets, 9e18);
        assertEq(shares, 0);
    }

    /// @dev L-01 boundary: repaying the exact debt `positionOf`/`describePosition` report must NOT take
    ///      the asset path (which converts the rounded-up value to more shares than held and underflows
    ///      on Morpho). The clamp routes a request at the reported debt to the dust-free share path.
    function test_encodeRepay_atReportedDebt_usesShares() public {
        _create();
        _seedBorrow(marketParams, account, 100e18, 100e18, 100e18);
        (, uint256 reportedDebt) = adapter.positionOf(account, market);
        (,, bytes memory data) = adapter.encodeRepay(account, market, reportedDebt);
        (uint256 assets, uint256 shares,) = this.decodeRepay(data);
        assertEq(assets, 0, "must not repay by assets at the reported debt");
        assertEq(shares, 100e18, "burns the account's full borrow share balance");
    }

    /// @dev A request above the reported debt likewise clamps to the share path rather than over-repaying.
    function test_encodeRepay_aboveReportedDebt_usesShares() public {
        _create();
        _seedBorrow(marketParams, account, 100e18, 100e18, 100e18);
        (, uint256 reportedDebt) = adapter.positionOf(account, market);
        (,, bytes memory data) = adapter.encodeRepay(account, market, reportedDebt + 1);
        (uint256 assets, uint256 shares,) = this.decodeRepay(data);
        assertEq(assets, 0);
        assertEq(shares, 100e18);
    }

    /// @dev L-01 boundary: a debt-free position (zero borrow shares) encodes a no-op the account skips,
    ///      instead of a `(0, 0)` repay Morpho rejects, so a generic repay-then-withdraw plan applies.
    function test_encodeRepay_zeroDebt_encodesNoOp() public {
        _create();
        // no borrow position seeded: borrowShares == 0
        (address target, uint256 value, bytes memory data) = adapter.encodeRepay(account, market, type(uint256).max);
        assertEq(target, address(morpho));
        assertEq(value, 0);
        assertEq(data.length, 0, "debt-free repay must be an empty no-op");
    }

    // ---- reads ----

    function test_maxLtvWad_returnsMarketLltv() public {
        _create();
        assertEq(Ltv.unwrap(adapter.maxLtvWad(market)), 0.86e18);
    }
}
