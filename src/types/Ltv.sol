// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice A loan-to-value ratio as a WAD (`1e18` == 100%). A type distinct from token amounts and
///         from `LeverageX18`, so health math cannot accidentally add an LTV to an amount or pass a
///         leverage where an LTV is expected.
type Ltv is uint256;

using {raw, lte, gt} for Ltv global;

/// @notice Wraps a raw WAD value as an `Ltv`.
function toLtv(uint256 wad) pure returns (Ltv) {
    return Ltv.wrap(wad);
}

/// @notice The raw WAD value of the LTV.
function raw(Ltv self) pure returns (uint256) {
    return Ltv.unwrap(self);
}

/// @notice True if `self <= other` (e.g. position LTV within the market max).
function lte(Ltv self, Ltv other) pure returns (bool) {
    return Ltv.unwrap(self) <= Ltv.unwrap(other);
}

/// @notice True if `self > other` (e.g. position LTV exceeds a target/limit).
function gt(Ltv self, Ltv other) pure returns (bool) {
    return Ltv.unwrap(self) > Ltv.unwrap(other);
}
