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
    /// @dev to be used when removing liquidity to guarantee a minimum output
    function validateMinOut(BalanceDelta delta, uint128 amount0Min, uint128 amount1Min) internal pure {
        // Called on decrease or burn, where we expect the returned delta to be positive.
        // Because we the slippage amountMins are uints, we SafeCast the delta returned. This will revert if the delta is negative.
        // Thus, this means this contract will NOT support pools where the hook returns a negative delta on burn/decrease.
        if (delta.amount0().toUint128() < amount0Min || delta.amount1().toUint128() < amount1Min) {
            revert MinimumAmountInsufficient();
        }
    }

    /// @notice Revert if one or both deltas exceeds a maximum input
    function validateMaxIn(BalanceDelta delta, uint128 amount0Max, uint128 amount1Max) internal pure {
        // Called on mint or increase, where we expect the returned delta to be negative.
        // However, in both mint or increase, a delta could be positive on specific hooked pools.
        // Thus we only cast the delta when the delta is negative. And that value we check against the amountMaxs.
        // If the delta is positive, we do not need to check against amount0Maxs as the min value is 0.
        if (
            delta.amount0() < 0 && amount0Max < uint128(-delta.amount0())
                || delta.amount1() < 0 && amount1Max < uint128(-delta.amount1())
        ) revert MaximumAmountExceeded();
    }
}
