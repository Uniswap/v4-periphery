// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ltv} from "./Ltv.sol";

/// @title PositionData
/// @author Uniswap Labs
/// @notice A consolidated snapshot of a leveraged position, returned by
///         `ILendingAdapter.describePosition`. It lets an integrator compose a position view in a
///         single call instead of separately reading `positionOf`, `maxLtvWad`, and `currentLtvWad`.
/// @dev No price fields: prices and liquidation prices are left to the offchain quoter, so this
///      snapshot needs no oracle-unit normalization and is uniform across every adapter.
/// @param collateralAmount The supplied collateral with accrued interest, in the collateral token's
///        native decimals.
/// @param debtAmount The outstanding debt with accrued interest, in the debt token's native decimals.
/// @param maxLtv The market's maximum (liquidation) LTV (WAD, 1e18 == 100%).
/// @param currentLtv The position's current LTV (WAD, 1e18 == 100%); zero when there is no debt.
/// @param healthFactorWad The position health factor (WAD, 1e18 == 1.0; below 1e18 is liquidatable),
///        i.e. `maxLtv / currentLtv`. `type(uint256).max` when there is no debt.
struct PositionData {
    uint256 collateralAmount;
    uint256 debtAmount;
    Ltv maxLtv;
    Ltv currentLtv;
    uint256 healthFactorWad;
}
