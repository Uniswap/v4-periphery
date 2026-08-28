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
    /// @notice Emitted when an exactInput hop's realized price (output per input, X36) falls below
    ///         its per-hop minimum
    error V4TooLittleReceivedPerHop(uint256 hopIndex, uint256 minPrice, uint256 price);
    /// @notice Emitted when an exactOutput hop's realized price (output per input, X36) falls below
    ///         its per-hop minimum, i.e. the hop consumed too much input for the output it bought
    error V4TooMuchRequestedPerHop(uint256 hopIndex, uint256 minPrice, uint256 price);
    /// @notice Emitted when a single exactInput swap's realized price (output per input, X36) falls
    ///         below its minimum
    error V4TooLittleReceivedPerHopSingle(uint256 minPrice, uint256 price);
    /// @notice Emitted when a single exactOutput swap's realized price (output per input, X36) falls
    ///         below its minimum, i.e. the swap consumed too much input for the output it bought
    error V4TooMuchRequestedPerHopSingle(uint256 minPrice, uint256 price);
    /// @notice Emitted when the length of the per-hop minimum price array is not zero and not equal to the path length
    error InvalidHopPriceLength();
    /// @notice Emitted when an exactOutput swap (or hop) delivers less than the requested amount, e.g. a
    ///         pool runs out of liquidity before the price limit. Exact output is all-or-nothing.
    error V4ExactOutputUnfilled(uint256 amountOutRequested, uint256 amountOutReceived);

    /// @notice Parameters for a single-hop exact-input swap
    /// @param poolKey The pool to swap through
    /// @param zeroForOne The swap direction
    /// @param amountIn The exact input amount (`OPEN_DELTA` resolves the router's full credit)
    /// @param amountOutMinimum The minimum acceptable output amount
    /// @param minHopPriceX36 The minimum realized price as output-per-input scaled by 1e36
    ///        (`amountOut * 1e36 / amountIn`); zero skips the price check
    /// @param hookData Arbitrary data passed to the pool's hooks
    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    /// @notice Parameters for a multi-hop exact-input swap
    /// @param currencyIn The input currency the path starts from
    /// @param path The swap path, one `PathKey` per hop
    /// @param minHopPriceX36 Per-hop minimum realized prices, each output-per-input scaled by 1e36;
    ///        an empty array skips all hop checks, otherwise the length must equal the path length
    ///        (one entry per hop, a zero entry skips that hop)
    /// @param amountIn The exact input amount (`OPEN_DELTA` resolves the router's full credit)
    /// @param amountOutMinimum The minimum acceptable final output amount
    struct ExactInputParams {
        Currency currencyIn;
        PathKey[] path;
        uint256[] minHopPriceX36;
        uint128 amountIn;
        uint128 amountOutMinimum;
    }

    /// @notice Parameters for a single-hop exact-output swap
    /// @param poolKey The pool to swap through
    /// @param zeroForOne The swap direction
    /// @param amountOut The exact output amount (`OPEN_DELTA` resolves the router's full debt)
    /// @param amountInMaximum The maximum acceptable input amount
    /// @param minHopPriceX36 The minimum realized price as output-per-input scaled by 1e36
    ///        (`amountOut * 1e36 / amountIn`); zero skips the price check
    /// @param hookData Arbitrary data passed to the pool's hooks
    struct ExactOutputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountOut;
        uint128 amountInMaximum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    /// @notice Parameters for a multi-hop exact-output swap
    /// @param currencyOut The output currency the path ends in
    /// @param path The swap path, one `PathKey` per hop
    /// @param minHopPriceX36 Per-hop minimum realized prices, each output-per-input scaled by 1e36;
    ///        an empty array skips all hop checks, otherwise the length must equal the path length
    ///        (one entry per hop, a zero entry skips that hop)
    /// @param amountOut The exact output amount (`OPEN_DELTA` resolves the router's full debt)
    /// @param amountInMaximum The maximum acceptable total input amount
    struct ExactOutputParams {
        Currency currencyOut;
        PathKey[] path;
        uint256[] minHopPriceX36;
        uint128 amountOut;
        uint128 amountInMaximum;
    }
}
