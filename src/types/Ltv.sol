// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Ltv
/// @author Uniswap Labs
/// @notice A loan-to-value ratio as a WAD value where `1e18` == 100%. A type distinct from raw token
///         amounts, so health math cannot accidentally add an LTV to a plain token amount.
type Ltv is uint256;

using {gt} for Ltv global;

/// @notice Wraps a raw WAD value as an `Ltv`.
/// @param wad The WAD-scaled LTV value (1e18 == 100%).
/// @return The wrapped `Ltv`.
function toLtv(uint256 wad) pure returns (Ltv) {
    return Ltv.wrap(wad);
}

/// @notice True if `self > other`. Used to detect that a position's LTV exceeds a target or
///         limit, e.g. to revert `PositionUnhealthy`.
/// @param self The LTV to compare.
/// @param other The bound to compare against.
/// @return True if `self` exceeds `other`.
function gt(Ltv self, Ltv other) pure returns (bool) {
    return Ltv.unwrap(self) > Ltv.unwrap(other);
}
