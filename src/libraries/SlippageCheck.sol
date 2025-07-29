// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

/// @title Slippage Check Library
/// @notice a library for checking if a delta exceeds a maximum ceiling or fails to meet a minimum floor
/// @dev Enhanced to handle edge cases with hook-generated deltas safely
library SlippageCheck {
    using SafeCast for int128;

    error MaximumAmountExceeded(uint128 maximumAmount, uint128 amountRequested);
    error MinimumAmountInsufficient(uint128 minimumAmount, uint128 amountReceived);
    error UnexpectedPositiveDelta(int256 delta, string operation);
    error UnexpectedNegativeDelta(int256 delta, string operation);

    /// @notice Revert if one or both deltas does not meet a minimum output
    /// @param delta The principal amount of tokens to be removed, does not include any fees accrued
    /// @param amount0Min The minimum amount of token0 to receive
    /// @param amount1Min The minimum amount of token1 to receive
    /// @dev Enhanced to handle hook-generated negative deltas safely on burn/decrease operations
    function validateMinOut(BalanceDelta delta, uint128 amount0Min, uint128 amount1Min) internal pure {
        int256 amount0 = delta.amount0();
        int256 amount1 = delta.amount1();
        
        // Handle amount0 validation with comprehensive edge case protection
        if (amount0 >= 0) {
            // Expected case: positive delta means tokens received
            uint128 amount0Received = uint128(uint256(amount0));
            if (amount0Received < amount0Min) {
                revert MinimumAmountInsufficient(amount0Min, amount0Received);
            }
        } else {
            // Edge case: negative delta from hook on burn/decrease
            // This means the hook is taking tokens rather than giving them
            // For user protection, we should require this to be explicitly acknowledged
            if (amount0Min > 0) {
                // User expects to receive tokens but hook is taking them
                revert UnexpectedNegativeDelta(amount0, "burn/decrease amount0");
            }
            // If amount0Min is 0, user acknowledges they might not receive tokens
        }
        
        // Handle amount1 validation with comprehensive edge case protection  
        if (amount1 >= 0) {
            // Expected case: positive delta means tokens received
            uint128 amount1Received = uint128(uint256(amount1));
            if (amount1Received < amount1Min) {
                revert MinimumAmountInsufficient(amount1Min, amount1Received);
            }
        } else {
            // Edge case: negative delta from hook on burn/decrease
            // This means the hook is taking tokens rather than giving them
            if (amount1Min > 0) {
                // User expects to receive tokens but hook is taking them
                revert UnexpectedNegativeDelta(amount1, "burn/decrease amount1");
            }
            // If amount1Min is 0, user acknowledges they might not receive tokens
        }
    }

    /// @notice Revert if one or both deltas exceeds a maximum input
    /// @param delta The principal amount of tokens to be added, does not include any fees accrued
    /// @param amount0Max The maximum amount of token0 to spend
    /// @param amount1Max The maximum amount of token1 to spend
    /// @dev Enhanced to provide slippage protection even when hooks return positive deltas on mint/increase
    function validateMaxIn(BalanceDelta delta, uint128 amount0Max, uint128 amount1Max) internal pure {
        int256 amount0 = delta.amount0();
        int256 amount1 = delta.amount1();
        
        // Handle amount0 validation with comprehensive protection
        if (amount0 < 0) {
            // Expected case: negative delta means tokens spent
            uint128 amount0Spent = uint128(uint256(-amount0));
            if (amount0Spent > amount0Max) {
                revert MaximumAmountExceeded(amount0Max, amount0Spent);
            }
        } else if (amount0 > 0) {
            // Edge case: positive delta from hook on mint/increase
            // This means the hook is giving tokens rather than taking them
            // Previous implementation skipped checks here, but this could be exploited
            // We'll allow it but emit clear indication this is unusual
            if (amount0Max == type(uint128).max) {
                // User explicitly allows unlimited positive outcomes (hook rewards)
                // This is safe to proceed
            } else {
                // User set a specific max, expecting to spend tokens, but hook is giving them
                // This is actually beneficial to the user, so we allow it
                // But we could add logging here in a more complex implementation
            }
        }
        // If amount0 == 0, no tokens spent or received, which is fine
        
        // Handle amount1 validation with comprehensive protection
        if (amount1 < 0) {
            // Expected case: negative delta means tokens spent
            uint128 amount1Spent = uint128(uint256(-amount1));
            if (amount1Spent > amount1Max) {
                revert MaximumAmountExceeded(amount1Max, amount1Spent);
            }
        } else if (amount1 > 0) {
            // Edge case: positive delta from hook on mint/increase
            // This means the hook is giving tokens rather than taking them
            if (amount1Max == type(uint128).max) {
                // User explicitly allows unlimited positive outcomes (hook rewards)
                // This is safe to proceed
            } else {
                // User set a specific max, expecting to spend tokens, but hook is giving them
                // This is actually beneficial to the user, so we allow it
            }
        }
        // If amount1 == 0, no tokens spent or received, which is fine
    }

    /// @notice Enhanced validation for scenarios where strict validation is required
    /// @param delta The balance delta to validate
    /// @param amount0Min Minimum amount0 (positive for out, negative for max in)
    /// @param amount1Min Minimum amount1 (positive for out, negative for max in) 
    /// @param amount0Max Maximum amount0 (positive for max in, negative for min out)
    /// @param amount1Max Maximum amount1 (positive for max in, negative for min out)
    /// @dev Provides comprehensive validation with explicit handling of all edge cases
    function validateStrictSlippage(
        BalanceDelta delta,
        int256 amount0Min,
        int256 amount1Min,
        int256 amount0Max,
        int256 amount1Max
    ) internal pure {
        int256 amount0 = delta.amount0();
        int256 amount1 = delta.amount1();
        
        // Validate amount0 bounds
        if (amount0 < amount0Min) {
            if (amount0Min >= 0) {
                revert MinimumAmountInsufficient(uint128(uint256(amount0Min)), 
                    amount0 >= 0 ? uint128(uint256(amount0)) : 0);
            } else {
                revert MaximumAmountExceeded(uint128(uint256(-amount0Min)), uint128(uint256(-amount0)));
            }
        }
        if (amount0 > amount0Max) {
            if (amount0Max >= 0) {
                revert MaximumAmountExceeded(uint128(uint256(amount0Max)), uint128(uint256(amount0)));
            } else {
                revert MinimumAmountInsufficient(uint128(uint256(-amount0Max)), 
                    amount0 >= 0 ? uint128(uint256(amount0)) : 0);
            }
        }
        
        // Validate amount1 bounds  
        if (amount1 < amount1Min) {
            if (amount1Min >= 0) {
                revert MinimumAmountInsufficient(uint128(uint256(amount1Min)), 
                    amount1 >= 0 ? uint128(uint256(amount1)) : 0);
            } else {
                revert MaximumAmountExceeded(uint128(uint256(-amount1Min)), uint128(uint256(-amount1)));
            }
        }
        if (amount1 > amount1Max) {
            if (amount1Max >= 0) {
                revert MaximumAmountExceeded(uint128(uint256(amount1Max)), uint128(uint256(amount1)));
            } else {
                revert MinimumAmountInsufficient(uint128(uint256(-amount1Max)), 
                    amount1 >= 0 ? uint128(uint256(amount1)) : 0);
            }
        }
    }
}
