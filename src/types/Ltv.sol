// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Ltv
/// @author Uniswap Labs
/// @notice A loan-to-value ratio as a WAD value where `1e18` == 100%. A type distinct from token
///         amounts and from `LeverageX18`, so health math cannot accidentally add an LTV to an
///         amount or pass a leverage value where an LTV is expected.
type Ltv is uint256;

using {raw, lte, gt} for Ltv global;

/// @notice Wraps a raw WAD value as an `Ltv`.
/// @param wad The WAD-scaled LTV value (1e18 == 100%).
/// @return The wrapped `Ltv`.
function toLtv(uint256 wad) pure returns (Ltv) {
    return Ltv.wrap(wad);
}

/// @notice Unwraps the `Ltv` to its raw WAD value.
/// @param self The `Ltv` to unwrap.
/// @return The raw WAD value (1e18 == 100%).
function raw(Ltv self) pure returns (uint256) {
    return Ltv.unwrap(self);
}

/// @notice True if `self <= other`. Used to check that a position's current LTV does not exceed
///         the market's maximum or a caller-supplied bound.
/// @param self The LTV to compare.
/// @param other The upper bound to compare against.
/// @return True if `self` is less than or equal to `other`.
function lte(Ltv self, Ltv other) pure returns (bool) {
    return Ltv.unwrap(self) <= Ltv.unwrap(other);
}

/// @notice True if `self > other`. Used to detect that a position's LTV exceeds a target or
///         limit, e.g. to revert `PositionUnhealthy`.
/// @param self The LTV to compare.
/// @param other The bound to compare against.
/// @return True if `self` exceeds `other`.
function gt(Ltv self, Ltv other) pure returns (bool) {
    return Ltv.unwrap(self) > Ltv.unwrap(other);
}
