// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {ImmutableState} from "./ImmutableState.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolInitializer} from "../interfaces/IPoolInitializer.sol";

abstract contract PoolInitializer is IPoolInitializer, ImmutableState {
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96, bytes calldata hookData)
        external
        returns (int24)
    {
        return poolManager.initialize(key, sqrtPriceX96, hookData);
    }
}
