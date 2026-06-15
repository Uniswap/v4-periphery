// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMorpho, IMorphoBase, MarketParams, Id, Position} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {MorphoLendingAdapter} from "../../src/MorphoLendingAdapter.sol";
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
    address internal receiver = makeAddr("receiver");

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
        adapter.encodeBorrow(account, market, 1e18, receiver);
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

    function test_encodeRepay_exactAmount_usesAssets() public {
        _register();
        (,, bytes memory data) = adapter.encodeRepay(account, market, 9e18);
        (uint256 assets, uint256 shares,) = this.decodeRepay(data);
        assertEq(assets, 9e18);
        assertEq(shares, 0);
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
