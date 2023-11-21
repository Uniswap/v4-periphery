//SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.20;

import {PathKey} from "./PathKey.sol";
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

struct ExactInputSingleBatchParams {
    PoolKey poolKey;
    bool[] zeroForOnes;
    address[] recipients;
    uint128[] amountIns;
    uint160[] sqrtPriceLimitX96s;
    bytes[] hookData;
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

struct ExactOutputSingleBatchParams {
    PoolKey poolKey;
    bool[] zeroForOnes;
    address[] recipients;
    uint128[] amountOuts;
    uint160[] sqrtPriceLimitX96s;
    bytes[] hookData;
}

struct ExactOutputParams {
    Currency currencyOut;
    PathKey[] path;
    address recipient;
    uint128 amountOut;
    uint160 sqrtPriceLimitX96;
}

library SwapIntention {
    function getPoolAndSwapDirection(PathKey memory params, Currency currencyIn)
        internal
        pure
        returns (PoolKey memory poolKey, bool zeroForOne)
    {
        (Currency currency0, Currency currency1) = currencyIn < params.intermediateCurrency
            ? (currencyIn, params.intermediateCurrency)
            : (params.intermediateCurrency, currencyIn);

        zeroForOne = currencyIn == currency0;
        poolKey = PoolKey(currency0, currency1, params.fee, params.tickSpacing, params.hooks);
    }
}
