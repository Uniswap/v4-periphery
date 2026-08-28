// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {CompoundV3LendingAdapter} from "../../src/CompoundV3LendingAdapter.sol";
import {Market} from "../../src/types/Market.sol";
import {Ltv} from "../../src/types/Ltv.sol";
import {PositionData} from "../../src/types/PositionData.sol";
import {MockComet} from "../mocks/MockComet.sol";

/// @notice Regression for the `describePosition` health-factor denominator. Health factor is
///         `mulDiv(collateralValue, liquidateCollateralFactor, debtValue)`, where `debtValue` is the
///         debt's USD value (`debt * price / baseScale`). For a base token whose decimals exceed its
///         USD price's precision (e.g. an 18-decimal WETH-base Comet) a small-but-non-zero raw debt has
///         a `debtValue` that rounds down to zero. The guard therefore keys off `debtValue` (the actual
///         divisor), not the raw debt amount, so such a dust debt returns a maximal (no-effective-debt)
///         health factor instead of dividing by zero. `increasePosition` and the partial-decrease
///         branch of `decreasePosition` build their events off `describePosition`, so this keeps those
///         paths available for any position whose debt lands in that dust range.
contract CompoundV3DustDivisionByZeroTest is Test {
    uint256 internal constant PRICE_SCALE = 1e8; // Comet/Chainlink-style 8-decimal USD price feed

    MockComet internal comet;
    CompoundV3LendingAdapter internal adapter;
    address internal gov = makeAddr("gov");
    address internal account = address(this);

    MockERC20 internal weth; // 18-decimal base token (models a WETH-base Comet, e.g. cWETHv3)
    MockERC20 internal uni; // collateral
    address internal wethFeed = makeAddr("wethFeed");
    address internal uniFeed = makeAddr("uniFeed");
    Market internal market;

    function setUp() public {
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        uni = new MockERC20("Uniswap", "UNI", 18);

        // WETH-base Comet: baseScale = 10**18, price = $2500 at 8-decimal scale.
        comet = new MockComet(address(weth), wethFeed, 1e18);
        comet.registerCollateral(address(uni), uniFeed, 1e18, 0.68e18, 0.74e18);
        comet.setPrice(wethFeed, 2500 * PRICE_SCALE);
        comet.setPrice(uniFeed, 7 * PRICE_SCALE);

        adapter = new CompoundV3LendingAdapter(comet, gov);
        market = Market({collateral: Currency.wrap(address(uni)), debt: Currency.wrap(address(weth))});
        vm.prank(gov);
        adapter.setMarket(market.collateral, market.debt, true);
    }

    /// @notice A 1-wei WETH debt has a USD value that rounds to zero; describePosition must still
    ///         return, reporting the raw debt and a maximal health factor rather than reverting.
    function test_describePosition_dustDebt_returnsMaxHealthFactor() public {
        comet.setCollateralBalance(account, address(uni), 1_000e18);
        comet.setBorrowBalance(account, 1); // debtValue = 1 * 2500e8 / 1e18 = 0 (floor)

        PositionData memory data = adapter.describePosition(account, market);
        assertEq(data.debtAmount, 1, "raw debt still reported");
        assertEq(data.healthFactorWad, type(uint256).max, "dust debt -> maximal health factor, no divide-by-zero");
        assertEq(Ltv.unwrap(data.currentLtv), 0, "dust debt -> zero current LTV");
    }

    /// @notice describePosition returns across the whole dust range and becomes finite once the debt's
    ///         USD value is non-zero.
    function test_describePosition_acrossDustRange_neverReverts() public {
        comet.setCollateralBalance(account, address(uni), 1_000e18);
        uint256 threshold = 1e18 / (2500 * PRICE_SCALE); // 4_000_000 wei: first debt with non-zero USD value
        assertGt(threshold, 1, "sanity: dust range is non-trivial");

        comet.setBorrowBalance(account, threshold - 1);
        PositionData memory dust = adapter.describePosition(account, market);
        assertEq(dust.healthFactorWad, type(uint256).max, "sub-threshold debt -> maximal health factor");

        // one wei above the threshold, the USD value is non-zero and the health factor is finite
        comet.setBorrowBalance(account, threshold);
        PositionData memory live = adapter.describePosition(account, market);
        assertLt(live.healthFactorWad, type(uint256).max, "at threshold the USD value is non-zero, health finite");
    }
}
