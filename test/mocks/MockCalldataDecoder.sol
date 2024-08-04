// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PositionConfig} from "../../src/libraries/PositionConfig.sol";
import {CalldataDecoder} from "../../src/libraries/CalldataDecoder.sol";
import {IV4Router} from "../../src/interfaces/IV4Router.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

// we need to use a mock contract to make the calls happen in calldata not memory
contract MockCalldataDecoder {
    using CalldataDecoder for bytes;

    function decodeModifyLiquidityParams(bytes calldata params)
        external
        pure
        returns (
            uint256 tokenId,
            PositionConfig calldata config,
            uint256 liquidity,
            uint128 amount0,
            uint128 amount1,
            bytes calldata hookData
        )
    {
        return params.decodeModifyLiquidityParams();
    }

    function decodeBurnParams(bytes calldata params)
        external
        pure
        returns (
            uint256 tokenId,
            PositionConfig calldata config,
            uint128 amount0Min,
            uint128 amount1Min,
            bytes calldata hookData
        )
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

    function decodeMintParams(bytes calldata params)
        external
        pure
        returns (
            PositionConfig calldata config,
            uint256 liquidity,
            uint128 amount0Max,
            uint128 amount1Max,
            address owner,
            bytes calldata hookData
        )
    {
        return params.decodeMintParams();
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
}
