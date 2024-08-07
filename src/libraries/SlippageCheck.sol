// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SafeCastTemp} from "./SafeCast.sol";

/// @title Slippage Check Library
/// @notice a library for checking if a delta exceeds a maximum ceiling or fails to meet a minimum floor
library SlippageCheckLibrary {
    using SafeCastTemp for int128;

    error MaximumAmountExceeded();
    error MinimumAmountInsufficient();

    /// @notice Revert if one or both deltas does not meet a minimum output
    /// @param delta The principal amount of tokens to be removed, does not include any fees accrued
    /// @param amount0Min The minimum amount of token0 to receive
    /// @param amount1Min The minimum amount of token1 to receive
    /// @dev This should be called when removing liquidity (burn or decrease)
    function validateMinOut(BalanceDelta delta, uint128 amount0Min, uint128 amount1Min) internal pure {
        // Called on burn or decrease, where we expect the returned delta to be positive.
        // However, on pools where hooks can return deltas on modify liquidity, it is possible for a returned delta to be negative.
        // Because we use SafeCast, this will revert in those cases when the delta is negative.
        // This means this contract will NOT support pools where the hook returns a negative delta on burn/decrease.
        if (delta.amount0().toUint128() < amount0Min || delta.amount1().toUint128() < amount1Min) {
            revert MinimumAmountInsufficient();
        }
    }

    /// @notice Revert if one or both deltas exceeds a maximum input
    /// @param delta The principal amount of tokens to be added, does not include any fees accrued (which is possible on increase)
    /// @param amount0Max The maximum amount of token0 to spend
    /// @param amount1Max The maximum amount of token1 to spend
    /// @dev This should be called when adding liquidity (mint or increase)
    function validateMaxIn(BalanceDelta delta, uint128 amount0Max, uint128 amount1Max) internal pure {
        // Called on mint or increase, where we expect the returned delta to be negative.
        // However, on pools where hooks can return deltas on modify liquidity, it is possible for a returned delta to be positive (even after discounting fees accrued).
        // Thus, we only cast the delta if it is guaranteed to be negative.
        // And we do NOT revert in the positive delta case. Since a positive delta means the hook is crediting tokens to the user for minting/increasing liquidity, we do not check slippage.
        // This means this contract will NOT support _positive_ slippage checks (minAmountOut checks) on pools where the hook returns a positive delta on mint/increase.
        if (
            delta.amount0() < 0 && amount0Max < uint128(-delta.amount0())
                || delta.amount1() < 0 && amount1Max < uint128(-delta.amount1())
        ) revert MaximumAmountExceeded();
    }
}
