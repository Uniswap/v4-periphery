// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {ExactInputSingleParams} from "../libraries/SwapIntention.sol";

interface IQuoter {
    error InvalidQuoteType();
    error UnexpectedRevertBytes();
    //function quoteExactInput(Path.PathKey calldata path, uint256 amountIn)
    //    external
    //    returns (uint256 amountOut, uint160[] memory sqrtPriceX96AfterList, uint32[] memory initializedTicksList);

    // enum QuoteType {
    //     ExactInput,
    //     ExactInputSingle,
    //     ExactOutput,
    //     ExactOutputSingle
    // }

    // struct QuoteInfo {
    //     QuoteType quoteType;
    //     address swapper;
    //     bytes params;
    // }

    // struct QuoteCallBackData {
    //     address swapper;
    //     PoolKey key;
    //     IPoolManager.SwapParams params;
    //     bytes hookData;
    // }

    // struct QuoteExactInputSingleParams {
    //     address swapper;
    //     Currency tokenIn;
    //     Currency tokenOut;
    //     PoolKey poolKey;
    //     uint256 amountIn;
    //     uint160 sqrtPriceLimitX96;
    //     bytes hookData;
    // }

    function quoteExactInputSingle(ExactInputSingleParams calldata params)
        external
        returns (int128 amount0Delta, int128 amount1Delta, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed);
}
