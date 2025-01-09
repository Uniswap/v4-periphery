// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IPoolInitializer_v4
/// @notice Interface for the PoolInitializer_v4 contract
interface IPoolInitializer_v4 {
    /// @notice Initialize a Uniswap v4 Pool
    /// @dev If the pool is already initialized, this function will not revert and just return type(int24).max
    /// @param key The PoolKey of the pool to initialize
    /// @param sqrtPriceX96 The initial starting price of the pool, expressed as a sqrtPriceX96
    /// @return The current tick of the pool, or type(int24).max if the pool creation failed, or the pool already existed
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external payable returns (int24);
}
