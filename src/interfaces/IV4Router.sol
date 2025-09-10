// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PathKey} from "../libraries/PathKey.sol";
import {IImmutableState} from "./IImmutableState.sol";

/// @title IV4Router
/// @notice Interface for the V4Router contract
interface IV4Router is IImmutableState {
    /// @notice Emitted when an exactInput swap does not receive its minAmountOut
    error V4TooLittleReceived(uint256 minAmountOutReceived, uint256 amountReceived);
    /// @notice Emitted when an exactOutput is asked for more than its maxAmountIn
    error V4TooMuchRequested(uint256 maxAmountInRequested, uint256 amountRequested);
    /// @notice Emitted when an exactInput swap does not receive its relative minAmountOut per hop (max price)
    error V4TooLittleReceivedPerHop(uint256 hopIndex, uint256 maxPrice, uint256 price);
    /// @notice Emitted when an exactOutput is asked for more than its relative maxAmountIn per hop (max price)
    error V4TooMuchRequestedPerHop(uint256 hopIndex, uint256 maxPrice, uint256 price);
    /// @notice Emitted when the length of the maxHopSlippage array is not zero and not equal to the path length
    error InvalidHopSlippageLength();

    /// @notice Parameters for a single-hop exact-input swap
    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }

    /// @notice Parameters for a multi-hop exact-input swap
    struct ExactInputParams {
        Currency currencyIn;
        PathKey[] path;
        uint256[] maxHopSlippage;
        uint128 amountIn;
        uint128 amountOutMinimum;
    }

    /// @notice Parameters for a single-hop exact-output swap
    struct ExactOutputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountOut;
        uint128 amountInMaximum;
        bytes hookData;
    }

    /// @notice Parameters for a multi-hop exact-output swap
    struct ExactOutputParams {
        Currency currencyOut;
        PathKey[] path;
        uint256[] maxHopSlippage;
        uint128 amountOut;
        uint128 amountInMaximum;
    }
}
