// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @title Safe casting methods
/// @notice Contains methods for safely casting between types
/// TODO after audits move this function to core's SafeCast.sol!
library HookFees {
    using BalanceDeltaLibrary for BalanceDelta;

    uint256 public constant MAX_BIPS = 10_000;

    /// @notice Calculates fee from a BalanceDelta and a percent
    /// @param delta The same delta from afterRemoveLiquidity
    /// @param maxFeeBips The maximum fee in basis points
    function calculateFeesFrom(BalanceDelta delta, uint256 maxFeeBips) internal pure returns (int256, int256) {
        unchecked {
            return (
                int128(int256(uint256(int256(delta.amount0())) * maxFeeBips / MAX_BIPS)),
                int128(int256(uint256(int256(delta.amount1())) * maxFeeBips / MAX_BIPS))
            );
        }
    }
}
