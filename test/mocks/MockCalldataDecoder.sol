// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PositionConfig} from "../../src/libraries/PositionConfig.sol";
import {CalldataDecoder} from "../../src/libraries/CalldataDecoder.sol";
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
}
