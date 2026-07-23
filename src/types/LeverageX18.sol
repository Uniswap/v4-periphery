// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title LeverageX18
/// @author Uniswap Labs
/// @notice Leverage expressed as a WAD multiplier where `1e18` == 1x. Sub-1x leverage is
///         unconstructable via `toLeverageX18`, so an invalid leverage value can never enter the
///         system as a value of this type. Distinct from `Ltv` and token amounts to prevent
///         accidental mixing in arithmetic.
type LeverageX18 is uint256;

using {raw, mulEquity} for LeverageX18 global;

// 1x leverage in WAD. Used as the lower bound in toLeverageX18.
uint256 constant ONE_X18 = 1e18;

/// @dev Thrown when constructing a leverage value below 1x (i.e. below `1e18`). Sub-1x is not
///      leverage; the type rejects it at construction time.
/// @param x18 The raw WAD value that was below `ONE_X18`.
error LeverageBelowOne(uint256 x18);

/// @notice Validates and wraps a raw WAD value as a `LeverageX18`. Reverts if `x18 < 1e18`
///         because sub-1x leverage is not a valid concept for this type.
/// @dev This is the only constructor for `LeverageX18`. All entry points that accept a leverage
///      argument should call this.
/// @param x18 The leverage as a WAD value (1e18 == 1x, 2e18 == 2x, etc.).
/// @return The wrapped `LeverageX18`.
function toLeverageX18(uint256 x18) pure returns (LeverageX18) {
    if (x18 < ONE_X18) revert LeverageBelowOne(x18);
    return LeverageX18.wrap(x18);
}

/// @notice Unwraps the `LeverageX18` to its raw WAD value.
/// @param self The `LeverageX18` to unwrap.
/// @return The raw WAD value (1e18 == 1x).
function raw(LeverageX18 self) pure returns (uint256) {
    return LeverageX18.unwrap(self);
}

/// @notice Computes the levered exposure for a given equity: `equity * leverage / 1e18`,
///         rounded down. Used by offchain quoters and router sizing helpers as a shared,
///         validated helper; the router does not solve for leverage onchain.
/// @param self The leverage multiplier (WAD, 1e18 == 1x).
/// @param equity The equity amount in any token's native decimals.
/// @return The total exposure (equity * leverage / 1e18), in the same units as `equity`.
function mulEquity(LeverageX18 self, uint256 equity) pure returns (uint256) {
    return (equity * LeverageX18.unwrap(self)) / ONE_X18;
}
