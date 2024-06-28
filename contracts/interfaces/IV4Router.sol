// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PathKey} from "../libraries/PathKey.sol";

/// @title UniswapV4Routing
/// @notice Abstract contract that contains all internal logic needed for routing through Uniswap V4 pools
interface IV4Router is IUnlockCallback {
    error NotPoolManager();
    error InvalidSwapType();
    error TooLittleReceived();
    error TooMuchRequested();

    struct SwapInfo {
        SwapType swapType;
        address msgSender;
        bytes params;
    }

    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        address recipient;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
        bytes hookData;
    }

    struct ExactInputParams {
        Currency currencyIn;
        PathKey[] path;
        address recipient;
        uint128 amountIn;
        uint128 amountOutMinimum;
    }

    struct ExactOutputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        address recipient;
        uint128 amountOut;
        uint128 amountInMaximum;
        uint160 sqrtPriceLimitX96;
        bytes hookData;
    }

    struct ExactOutputParams {
        Currency currencyOut;
        PathKey[] path;
        address recipient;
        uint128 amountOut;
        uint128 amountInMaximum;
    }

    enum SwapType {
        ExactInput,
        ExactInputSingle,
        ExactOutput,
        ExactOutputSingle
    }
}
