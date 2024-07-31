// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @title Slippage Check Library
/// @notice a library for checking if a delta exceeds a maximum ceiling or fails to meet a minimum floor
library SlippageCheckLibrary {
    error MaximumAmountExceeded();
    error MinimumAmountInsufficient();

    /// @notice Revert if one or both deltas does not meet a minimum output
    /// @dev to be used when removing liquidity to guarantee a minimum output
    function validateMinimumOut(BalanceDelta delta, uint128 amount0Min, uint128 amount1Min) internal pure {
        if (uint128(delta.amount0()) < amount0Min || uint128(delta.amount1()) < amount1Min) {
            revert MinimumAmountInsufficient();
        }
    }

    /// @notice Revert if one or both deltas exceeds a maximum input
    /// @dev to be used when minting liquidity to guarantee a maximum input
    function validateMaximumIn(BalanceDelta delta, uint128 amount0Max, uint128 amount1Max) internal pure {
        if (uint128(-delta.amount0()) > amount0Max || uint128(-delta.amount1()) > amount1Max) {
            revert MaximumAmountExceeded();
        }
    }

    /// @notice Revert if one or both deltas exceeds a maximum input
    /// @dev When increasing liquidity, delta can be positive when excess fees need to be collected
    /// in those cases, slippage checks are not required
    function validateMaximumIncreaseSlippage(BalanceDelta delta, uint128 amount0Max, uint128 amount1Max)
        internal
        pure
    {
        if (
            delta.amount0() < 0 && amount0Max < uint128(-delta.amount0())
                || delta.amount1() < 0 && amount1Max < uint128(-delta.amount1())
        ) revert MaximumAmountExceeded();
    }
}
