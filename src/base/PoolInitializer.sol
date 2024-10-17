// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {ImmutableState} from "./ImmutableState.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title Pool Initializer
/// @notice Initializes a Uniswap v4 Pool
/// @dev Enables create pool + mint liquidity in a single transaction with multicall
abstract contract PoolInitializer is ImmutableState {
    /// @notice Initialize a Uniswap v4 Pool
    /// @param key the PoolKey of the pool to initialize
    /// @param sqrtPriceX96 the initial sqrtPriceX96 of the pool
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external payable returns (int24) {
        return poolManager.initialize(key, sqrtPriceX96);
    }
}
