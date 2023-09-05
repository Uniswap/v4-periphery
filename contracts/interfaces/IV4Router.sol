// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/console.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";

/// @title UniswapV4Routing
/// @notice Abstract contract that contains all internal logic needed for routing through Uniswap V4 pools
interface IV4Router {
    error NotPoolManager();
    error InvalidSwapType();
    error TooLittleReceived();
    error TooMuchRequested();

    struct SwapInfo {
        SwapType swapType;
        address msgSender;
        bytes params;
    }

    struct PathKey {
        Currency tradeCurrency;
        uint24 fee;
        int24 tickSpacing;
        IHooks hooks;
    }

    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        address recipient;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
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

    function lockAcquired(bytes calldata encodedSwapInfo) external returns (bytes memory);
}
