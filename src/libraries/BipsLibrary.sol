// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.19;

/// @title For calculating a percentage of an amount, using bips
library BipsLibrary {
    uint256 internal constant BIPS_BASE = 10_000;

    /// @notice emitted when an invalid percentage is provided
    error InvalidBips();

    /// @param amount The total amount to calculate a percentage of
    /// @param bips The percentage to calculate, in bips
    function calculatePortion(uint256 amount, uint256 bips) internal pure returns (uint256) {
        if (bips > BIPS_BASE) revert InvalidBips();
        return (amount * bips) / BIPS_BASE;
    }
}
