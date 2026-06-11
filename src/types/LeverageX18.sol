// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Leverage as a WAD multiplier where `1e18` == 1x. Sub-1x leverage is unconstructable,
///         so an invalid "leverage" can never enter the system as a value of this type.
type LeverageX18 is uint256;

using {raw, mulEquity} for LeverageX18 global;

// 1x leverage in WAD.
uint256 constant ONE_X18 = 1e18;

/// @notice Thrown when constructing a leverage below 1x (`1e18`).
error LeverageBelowOne(uint256 x18);

/// @notice Validates and wraps a raw WAD value as a `LeverageX18` (must be `>= 1e18`).
/// @dev The only constructor. A value `< 1e18` is not leverage, so it reverts rather than wrapping.
function toLeverageX18(uint256 x18) pure returns (LeverageX18) {
    if (x18 < ONE_X18) revert LeverageBelowOne(x18);
    return LeverageX18.wrap(x18);
}

/// @notice The raw WAD value of the leverage.
function raw(LeverageX18 self) pure returns (uint256) {
    return LeverageX18.unwrap(self);
}

/// @notice Levered exposure for a given equity amount: `equity * leverage / 1e18` (rounded down).
/// @dev Used by the router's pure sizing helpers and the offchain quoter as a shared, validated
///      type. The contract does not solve for leverage onchain.
function mulEquity(LeverageX18 self, uint256 equity) pure returns (uint256) {
    return (equity * LeverageX18.unwrap(self)) / ONE_X18;
}
