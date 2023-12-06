//SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.20;

import {PathKey, PathKeyLib} from "./PathKey.sol";
import {Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";

enum SwapType {
    ExactInput,
    ExactInputSingle,
    ExactOutput,
    ExactOutputSingle
}

struct SwapInfo {
    SwapType swapType;
    bytes params;
}

struct ExactInputSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    address recipient;
    uint128 amountIn;
    uint160 sqrtPriceLimitX96;
    bytes hookData;
}

struct ExactInputParams {
    Currency currencyIn;
    PathKey[] path;
    address recipient;
    uint128 amountIn;
}

struct ExactOutputSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    address recipient;
    uint128 amountOut;
    uint160 sqrtPriceLimitX96;
    bytes hookData;
}

struct ExactOutputParams {
    Currency currencyOut;
    PathKey[] path;
    address recipient;
    uint128 amountOut;
    uint160 sqrtPriceLimitX96;
}
