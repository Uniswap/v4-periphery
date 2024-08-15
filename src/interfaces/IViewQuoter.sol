// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @title Quoter Interface
/// @notice Supports quoting the calculated amounts from hookless swaps.
interface IViewQuoter {
    /// @notice Returns the amount taken or received for a swap of a single pool
    /// @param poolKey The poolKey identifying the pool traded against
    /// currency0
    /// currency1
    /// fee
    /// tickSpacing
    /// hooks
    /// @param swapParams The parameters used for the swap
    /// zeroForOne
    /// amountSpecified
    /// sqrtPriceLimitX96
    /// @return amount0 the amount of token0 sent in or out of the pool
    /// @return amount1 the amount of token1 sent in or out of the pool
    /// @return sqrtPriceAfterX96 the price of the pool after the swap
    /// @return initializedTicksCrossed the number of initialized ticks LOADED IN
    function quoteSingle(PoolKey calldata poolKey, IPoolManager.SwapParams calldata swapParams)
        external
        view
        returns (int256, int256, uint160, uint32);
}
