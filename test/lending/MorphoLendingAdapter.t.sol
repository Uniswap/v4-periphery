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
import {PositionAmountResolver} from "../../src/base/PositionAmountResolver.sol";
import {Market} from "../../src/types/Market.sol";
import {MarketNotSupported} from "../../src/types/MarketRegistry.sol";
import {NotOwner, ZeroOwner, NotPendingOwner} from "../../src/types/Owner.sol";
import {Ltv} from "../../src/types/Ltv.sol";
import {MockMorpho} from "../mocks/MockMorpho.sol";

contract MorphoLendingAdapterTest is Test {
    using MarketParamsLib for MarketParams;

    MockMorpho internal morpho;
    MorphoLendingAdapter internal adapter;

    address internal gov = makeAddr("gov");
    address internal stranger = makeAddr("stranger");
    address internal account = makeAddr("account");

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
        morpho.setMarketParams(marketParams); // make the market "exist" on Morpho
        vm.prank(gov);
        adapter.setMarket(marketParams);
    }

    /// @dev Seeds a borrow position plus 1:1 market totals with `lastUpdate == block.timestamp` so
    ///      accrual is skipped, making `expectedBorrowAssets` a deterministic function of the shares.
    function _seedBorrow(address who, uint128 borrowShares, uint128 totalBorrowAssets, uint128 totalBorrowShares)
        internal
    {
        Id id = marketParams.id();
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

    function decodeRepay(bytes calldata d) external pure returns (uint256 assets, uint256 shares, address onBehalf) {
        MarketParams memory mp;
        bytes memory inner;
        (mp, assets, shares, onBehalf, inner) = abi.decode(d[4:], (MarketParams, uint256, uint256, address, bytes));
    }

    function test_lendingProtocol_returnsMorphoSingleton() public view {
        assertEq(adapter.lendingProtocol(), address(morpho));
    }

    /// @dev The adapter doubles as an IAmountResolver; the resolver read routes through the same
    ///      registry gate as positionOf, so an unrouted pair reverts rather than resolving zero.
    function test_resolveAmount_revertsWhenMarketNotSupported() public {
        bytes memory context = abi.encode(PositionAmountResolver.PositionAmount.DEBT, account, market);
        vm.expectRevert(abi.encodeWithSelector(MarketNotSupported.selector, market.collateral, market.debt));
        adapter.resolveAmount(context);
    }

    function test_setMarket_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotOwner.selector, stranger));
        adapter.setMarket(marketParams);
    }

    function test_setMarket_revertsWhenMorphoMarketNotCreated() public {
        // morpho.idToMarketParams is unset, so the market does not exist on Morpho
        vm.prank(gov);
        vm.expectRevert(MorphoLendingAdapter.MorphoMarketNotCreated.selector);
        adapter.setMarket(marketParams);
    }

    function test_setMarket_succeeds_andMarketIsSupported() public {
        _register();
        assertTrue(adapter.isSupportedMarket(market));
    }

    function test_encodeBorrow_revertsWhenMarketNotSupported() public {
        vm.expectRevert(abi.encodeWithSelector(MarketNotSupported.selector, market.collateral, market.debt));
        adapter.encodeBorrow(account, market, 1e18);
    }

    function test_encodeSupplyCollateral_targetOnBehalfAndEmptyData() public {
        _register();
        (address target, uint256 value, bytes memory data) = adapter.encodeSupplyCollateral(account, market, 5e18);
        assertEq(target, address(morpho));
        assertEq(value, 0);
        assertEq(bytes4(data), IMorphoBase.supplyCollateral.selector);
        (uint256 amount, address onBehalf, uint256 dataLen) = this.decodeSupply(data);
        assertEq(amount, 5e18);
        assertEq(onBehalf, account); // the account is always the onBehalf
        assertEq(dataLen, 0); // empty data so no Morpho callback fires
    }

    function test_encodeRepay_max_usesSharesBasedFullRepay() public {
        _register();
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
        _register();
        // reported debt ~100e18; a request well below it is a genuine partial and stays asset-denominated
        _seedBorrow(account, 100e18, 100e18, 100e18);
        (,, bytes memory data) = adapter.encodeRepay(account, market, 9e18);
        (uint256 assets, uint256 shares,) = this.decodeRepay(data);
        assertEq(assets, 9e18);
        assertEq(shares, 0);
    }

    /// @dev L-01 boundary: repaying the exact debt `positionOf`/`describePosition` report must NOT take
    ///      the asset path (which converts the rounded-up value to more shares than held and underflows
    ///      on Morpho). The clamp routes a request at the reported debt to the dust-free share path.
    function test_encodeRepay_atReportedDebt_usesShares() public {
        _register();
        _seedBorrow(account, 100e18, 100e18, 100e18);
        (, uint256 reportedDebt) = adapter.positionOf(account, market);
        (,, bytes memory data) = adapter.encodeRepay(account, market, reportedDebt);
        (uint256 assets, uint256 shares,) = this.decodeRepay(data);
        assertEq(assets, 0, "must not repay by assets at the reported debt");
        assertEq(shares, 100e18, "burns the account's full borrow share balance");
    }

    /// @dev A request above the reported debt likewise clamps to the share path rather than over-repaying.
    function test_encodeRepay_aboveReportedDebt_usesShares() public {
        _register();
        _seedBorrow(account, 100e18, 100e18, 100e18);
        (, uint256 reportedDebt) = adapter.positionOf(account, market);
        (,, bytes memory data) = adapter.encodeRepay(account, market, reportedDebt + 1);
        (uint256 assets, uint256 shares,) = this.decodeRepay(data);
        assertEq(assets, 0);
        assertEq(shares, 100e18);
    }

    /// @dev L-01 boundary: a debt-free position (zero borrow shares) encodes a no-op the account skips,
    ///      instead of a `(0, 0)` repay Morpho rejects, so a generic repay-then-withdraw plan applies.
    function test_encodeRepay_zeroDebt_encodesNoOp() public {
        _register();
        // no borrow position seeded: borrowShares == 0
        (address target, uint256 value, bytes memory data) = adapter.encodeRepay(account, market, type(uint256).max);
        assertEq(target, address(morpho));
        assertEq(value, 0);
        assertEq(data.length, 0, "debt-free repay must be an empty no-op");
    }

    function test_maxLtvWad_returnsMarketLltv() public {
        _register();
        assertEq(Ltv.unwrap(adapter.maxLtvWad(market)), 0.86e18);
    }

    function test_owner_isConstructorOwner() public view {
        assertEq(adapter.owner(), gov);
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

    function test_acceptOwnership_completesHandoff() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(gov);
        adapter.transferOwnership(newOwner);

        vm.prank(newOwner);
        adapter.acceptOwnership();

        assertEq(adapter.owner(), newOwner);
        assertEq(adapter.pendingOwner(), address(0));
    }

    function test_oldOwnerRetainsPowerUntilAccept() public {
        morpho.setMarketParams(marketParams); // make the market "exist" on Morpho
        vm.prank(gov);
        adapter.transferOwnership(makeAddr("newOwner"));
        // the old owner can still register markets before the handoff completes
        vm.prank(gov);
        adapter.setMarket(marketParams);
        assertTrue(adapter.isSupportedMarket(market));
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
}
