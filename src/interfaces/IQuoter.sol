// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PathKey} from "../libraries/PathKey.sol";

/// @title Quoter Interface
/// @notice Supports quoting the delta amounts for exact input or exact output swaps.
/// @notice For each pool also tells you the number of initialized ticks loaded and the sqrt price of the pool after the swap.
/// @dev These functions are not marked view because they rely on calling non-view functions and reverting
/// to compute the result. They are also not gas efficient and should not be called on-chain.
interface IQuoter {
    error InvalidLockCaller();
    error InvalidQuoteBatchParams();
    error InsufficientAmountOut();
    error LockFailure();
    error NotSelf();
    error UnexpectedRevertBytes(bytes revertData);

    struct PoolDeltas {
        int128 currency0Delta;
        int128 currency1Delta;
    }

    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        uint160 sqrtPriceLimitX96;
        bytes hookData;
    }

    struct QuoteExactParams {
        Currency exactCurrency;
        PathKey[] path;
        uint128 exactAmount;
    }

    /// @notice Returns the delta amounts for a given exact input swap of a single pool
    /// @param params The params for the quote, encoded as `QuoteExactSingleParams`
    /// poolKey The key for identifying a V4 pool
    /// zeroForOne If the swap is from currency0 to currency1
    /// exactAmount The desired input amount
    /// sqrtPriceLimitX96 The price limit of the pool that cannot be exceeded by the swap
    /// hookData arbitrary hookData to pass into the associated hooks
    /// @return deltaAmounts Delta amounts resulted from the swap
    /// @return sqrtPriceX96After The sqrt price of the pool after the swap
    /// @return initializedTicksLoaded The number of initialized ticks that the swap loaded
    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (int128[] memory deltaAmounts, uint160 sqrtPriceX96After, uint32 initializedTicksLoaded);

    /// @notice Returns the delta amounts along the swap path for a given exact input swap
    /// @param params the params for the quote, encoded as 'QuoteExactParams'
    /// currencyIn The input currency of the swap
    /// path The path of the swap encoded as PathKeys that contains currency, fee, tickSpacing, and hook info
    /// exactAmount The desired input amount
    /// @return deltaAmounts Delta amounts along the path resulted from the swap
    /// @return sqrtPriceX96AfterList List of the sqrt price after the swap for each pool in the path
    /// @return initializedTicksLoadedList List of the initialized ticks that the swap loaded for each pool in the path
    function quoteExactInput(QuoteExactParams memory params)
        external
        returns (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        );

    /// @notice Returns the delta amounts for a given exact output swap of a single pool
    /// @param params The params for the quote, encoded as `QuoteExactSingleParams`
    /// poolKey The key for identifying a V4 pool
    /// zeroForOne If the swap is from currency0 to currency1
    /// exactAmount The desired output amount
    /// sqrtPriceLimitX96 The price limit of the pool that cannot be exceeded by the swap
    /// hookData arbitrary hookData to pass into the associated hooks
    /// @return deltaAmounts Delta amounts resulted from the swap
    /// @return sqrtPriceX96After The sqrt price of the pool after the swap
    /// @return initializedTicksLoaded The number of initialized ticks that the swap loaded
    function quoteExactOutputSingle(QuoteExactSingleParams memory params)
        external
        returns (int128[] memory deltaAmounts, uint160 sqrtPriceX96After, uint32 initializedTicksLoaded);

    /// @notice Returns the delta amounts along the swap path for a given exact output swap
    /// @param params the params for the quote, encoded as 'QuoteExactParams'
    /// currencyOut The output currency of the swap
    /// path The path of the swap encoded as PathKeys that contains currency, fee, tickSpacing, and hook info
    /// exactAmount The desired output amount
    /// @return deltaAmounts Delta amounts along the path resulted from the swap
    /// @return sqrtPriceX96AfterList List of the sqrt price after the swap for each pool in the path
    /// @return initializedTicksLoadedList List of the initialized ticks that the swap loaded for each pool in the path
    function quoteExactOutput(QuoteExactParams memory params)
        external
        returns (
            int128[] memory deltaAmounts,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksLoadedList
        );
}
