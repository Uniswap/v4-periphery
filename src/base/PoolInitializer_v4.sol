// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ImmutableState} from "./ImmutableState.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolInitializer_v4} from "../interfaces/IPoolInitializer_v4.sol";

/// @title Pool Initializer
/// @notice Initializes a Uniswap v4 Pool
/// @dev Enables create pool + mint liquidity in a single transaction with multicall
abstract contract PoolInitializer_v4 is ImmutableState, IPoolInitializer_v4 {
    /// @inheritdoc IPoolInitializer_v4
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external payable returns (int24) {
        try poolManager.initialize(key, sqrtPriceX96) returns (int24 tick) {
            return tick;
        } catch {
            return type(int24).max;
        }
    }
}
