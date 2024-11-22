// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CalldataDecoder} from "../../src/libraries/CalldataDecoder.sol";
import {IV4Router} from "../../src/interfaces/IV4Router.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

// we need to use a mock contract to make the calls happen in calldata not memory
contract MockCalldataDecoder {
    using CalldataDecoder for bytes;

    // This is used to avoid compiling with via-ir.
    struct MintParams {
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        uint256 liquidity;
        uint128 amount0Max;
        uint128 amount1Max;
        address owner;
        bytes hookData;
    }

    struct MintFromDeltasParams {
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        uint128 amount0Max;
        uint128 amount1Max;
        address owner;
        bytes hookData;
    }

    function decodeActionsRouterParams(bytes calldata params)
        external
        pure
        returns (bytes calldata actions, bytes[] calldata actionParams)
    {
        return params.decodeActionsRouterParams();
    }

    function decodeModifyLiquidityParams(bytes calldata params)
        external
        pure
        returns (uint256 tokenId, uint256 liquidity, uint128 amount0, uint128 amount1, bytes calldata hookData)
    {
        return params.decodeModifyLiquidityParams();
    }

    function decodeBurnParams(bytes calldata params)
        external
        pure
        returns (uint256 tokenId, uint128 amount0Min, uint128 amount1Min, bytes calldata hookData)
    {
        return params.decodeBurnParams();
    }

    function decodeSwapExactInParams(bytes calldata params)
        external
        pure
        returns (IV4Router.ExactInputParams calldata swapParams)
    {
        return params.decodeSwapExactInParams();
    }

    function decodeSwapExactInSingleParams(bytes calldata params)
        external
        pure
        returns (IV4Router.ExactInputSingleParams calldata swapParams)
    {
        return params.decodeSwapExactInSingleParams();
    }

    function decodeSwapExactOutParams(bytes calldata params)
        external
        pure
        returns (IV4Router.ExactOutputParams calldata swapParams)
    {
        return params.decodeSwapExactOutParams();
    }

    function decodeSwapExactOutSingleParams(bytes calldata params)
        external
        pure
        returns (IV4Router.ExactOutputSingleParams calldata swapParams)
    {
        return params.decodeSwapExactOutSingleParams();
    }

    function decodeMintParams(bytes calldata params) external pure returns (MintParams memory mintParams) {
        (
            PoolKey memory poolKey,
            int24 tickLower,
            int24 tickUpper,
            uint256 liquidity,
            uint128 amount0Max,
            uint128 amount1Max,
            address owner,
            bytes memory hookData
        ) = params.decodeMintParams();
        return MintParams({
            poolKey: poolKey,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            amount0Max: amount0Max,
            amount1Max: amount1Max,
            owner: owner,
            hookData: hookData
        });
    }

    function decodeCurrencyAndAddress(bytes calldata params)
        external
        pure
        returns (Currency currency, address _address)
    {
        return params.decodeCurrencyAndAddress();
    }

    function decodeCurrency(bytes calldata params) external pure returns (Currency currency) {
        return params.decodeCurrency();
    }

    function decodeCurrencyPair(bytes calldata params) external pure returns (Currency currency0, Currency currency1) {
        return params.decodeCurrencyPair();
    }

    function decodeCurrencyPairAndAddress(bytes calldata params)
        external
        pure
        returns (Currency currency0, Currency currency1, address _address)
    {
        return params.decodeCurrencyPairAndAddress();
    }

    function decodeCurrencyAndUint256(bytes calldata params) external pure returns (Currency currency, uint256 _uint) {
        return params.decodeCurrencyAndUint256();
    }

    function decodeCurrencyAddressAndUint256(bytes calldata params)
        external
        pure
        returns (Currency currency, address addr, uint256 amount)
    {
        return params.decodeCurrencyAddressAndUint256();
    }

    function decodeIncreaseLiquidityFromDeltasParams(bytes calldata params)
        external
        pure
        returns (uint256 tokenId, uint128 amount0Max, uint128 amount1Max, bytes calldata hookData)
    {
        return params.decodeIncreaseLiquidityFromDeltasParams();
    }

    function decodeMintFromDeltasParams(bytes calldata params)
        external
        pure
        returns (MintFromDeltasParams memory mintParams)
    {
        (
            PoolKey memory poolKey,
            int24 tickLower,
            int24 tickUpper,
            uint128 amount0Max,
            uint128 amount1Max,
            address owner,
            bytes memory hookData
        ) = params.decodeMintFromDeltasParams();
        return MintFromDeltasParams({
            poolKey: poolKey,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Max: amount0Max,
            amount1Max: amount1Max,
            owner: owner,
            hookData: hookData
        });
    }

    function decodeUint256(bytes calldata params) external pure returns (uint256) {
        return params.decodeUint256();
    }

    function decodeCurrencyUint256AndBool(bytes calldata params) external pure returns (Currency, uint256, bool) {
        return params.decodeCurrencyUint256AndBool();
    }
}
