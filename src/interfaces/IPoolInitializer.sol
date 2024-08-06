// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title Pool Initializer
/// @notice Initializes a pool on PoolManager
interface IPoolInitializer {
    /// @notice Initializes a pool on PoolManager
    /// @param key The PoolKey of the pool to initialize
    /// @param sqrtPriceX96 The starting price of the pool, expressed as sqrtPriceX96
    /// @param hookData Arbitrary data to pass to the pool, forwarded to initialize hook functions
    /// @return tick The starting tick of the pool
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96, bytes calldata hookData)
        external
        returns (int24);
}
