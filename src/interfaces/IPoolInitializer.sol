// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IPoolInitializer {
    /// @notice Initialize a Uniswap v4 Pool
    /// @dev If the pool is already initialized, this function will not revert and just return type(int24).max
    /// @param key the PoolKey of the pool to initialize
    /// @param sqrtPriceX96 the initial sqrtPriceX96 of the pool
    /// @return tick The current tick of the pool
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external payable returns (int24);
}
