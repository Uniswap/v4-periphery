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
///         debt's USD value (`debt * price / baseScale`, rounded up). Rounding up means any non-zero
///         debt against a non-zero price has a non-zero `debtValue`, so a dust debt reports a large but
///         finite health factor. The guard still keys off `debtValue` (the actual divisor), not the raw
///         debt amount, so a zero price (a feed reporting no value) returns a maximal health factor
///         instead of dividing by zero. `increasePosition` and the partial-decrease branch of
///         `decreasePosition` build their events off `describePosition`, so this keeps those paths
///         available.
contract CompoundV3DustDivisionByZeroTest is Test {
    uint256 internal constant PRICE_SCALE = 1e8; // Comet/Chainlink-style 8-decimal USD price feed

    MockComet internal comet;
    CompoundV3LendingAdapter internal adapter;
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

        adapter = new CompoundV3LendingAdapter(comet);
        // a Comet market is the collateral asset alone, so the key carries no data
        market = Market({collateral: Currency.wrap(address(uni)), debt: Currency.wrap(address(weth)), data: ""});
    }

    /// @notice A 1-wei WETH debt is valued at one price unit (rounded up), not zero: describePosition
    ///         reports the raw debt and a finite health factor.
    function test_describePosition_dustDebt_isValuedAtLeastOneUnit() public {
        comet.setCollateralBalance(account, address(uni), 1_000e18);
        comet.setBorrowBalance(account, 1); // debtValue = ceil(1 * 2500e8 / 1e18) = 1

        PositionData memory data = adapter.describePosition(account, market);
        assertEq(data.debtAmount, 1, "raw debt still reported");
        // collateralValue = 1000e18 * 7e8 / 1e18 = 7e11; health = 7e11 * 0.74e18 / 1
        assertEq(data.healthFactorWad, 7e11 * 0.74e18, "dust debt is valued at one unit, health finite");
        assertGt(Ltv.unwrap(data.currentLtv), 0, "dust debt -> non-zero current LTV");
    }

    /// @notice describePosition does not divide by zero when the debt feed reports a zero price.
    function test_describePosition_zeroDebtPrice_returnsMaxHealthFactor() public {
        comet.setCollateralBalance(account, address(uni), 1_000e18);
        comet.setBorrowBalance(account, 1e18);
        comet.setPrice(wethFeed, 0); // debtValue = 0 for a non-zero raw debt

        PositionData memory data = adapter.describePosition(account, market);
        assertEq(data.debtAmount, 1e18, "raw debt still reported");
        assertEq(data.healthFactorWad, type(uint256).max, "zero debt value -> maximal health factor, no divide-by-zero");
        assertEq(Ltv.unwrap(data.currentLtv), 0, "zero debt value -> zero current LTV");
    }
}
