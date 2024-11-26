// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ImmutableState} from "./ImmutableState.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolInitializer} from "../interfaces/IPoolInitializer.sol";

/// @title Pool Initializer
/// @notice Initializes a Uniswap v4 Pool
/// @dev Enables create pool + mint liquidity in a single transaction with multicall
abstract contract PoolInitializer is ImmutableState, IPoolInitializer {
    /// @inheritdoc IPoolInitializer
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external payable returns (int24) {
        try poolManager.initialize(key, sqrtPriceX96) returns (int24 tick) {
            return tick;
        } catch {
            return type(int24).max;
        }
    }
}
