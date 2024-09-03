// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {ImmutableState} from "./ImmutableState.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

abstract contract PoolInitializer is ImmutableState {
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96, bytes calldata hookData)
        external
        payable
        returns (int24)
    {
        return poolManager.initialize(key, sqrtPriceX96, hookData);
    }
}
