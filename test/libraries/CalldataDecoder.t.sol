// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {MockCalldataDecoder} from "../mocks/MockCalldataDecoder.sol";
import {PositionConfig} from "../../src/libraries/PositionConfig.sol";
import {IV4Router} from "../../src/interfaces/IV4Router.sol";
import {PathKey} from "../../src/libraries/PathKey.sol";

contract CalldataDecoderTest is Test {
    MockCalldataDecoder decoder;

    function setUp() public {
        decoder = new MockCalldataDecoder();
    }

    function test_fuzz_decodeModifyLiquidityParams(
        uint256 _tokenId,
        PositionConfig calldata _config,
        uint256 _liquidity,
        uint128 _amount0,
        uint128 _amount1,
        bytes calldata _hookData
    ) public view {
        bytes memory params = abi.encode(_tokenId, _config, _liquidity, _amount0, _amount1, _hookData);
        (
            uint256 tokenId,
            PositionConfig memory config,
            uint256 liquidity,
            uint128 amount0,
            uint128 amount1,
            bytes memory hookData
        ) = decoder.decodeModifyLiquidityParams(params);

        assertEq(tokenId, _tokenId);
        assertEq(liquidity, _liquidity);
        assertEq(amount0, _amount0);
        assertEq(amount1, _amount1);
        assertEq(hookData, _hookData);
        _assertEq(_config, config);
    }

    function test_fuzz_decodeBurnParams(
        uint256 _tokenId,
        PositionConfig calldata _config,
        uint128 _amount0Min,
        uint128 _amount1Min,
        bytes calldata _hookData
    ) public view {
        bytes memory params = abi.encode(_tokenId, _config, _amount0Min, _amount1Min, _hookData);
        (uint256 tokenId, PositionConfig memory config, uint128 amount0Min, uint128 amount1Min, bytes memory hookData) =
            decoder.decodeBurnParams(params);

        assertEq(tokenId, _tokenId);
        assertEq(hookData, _hookData);
        _assertEq(_config, config);
        assertEq(amount0Min, _amount0Min);
        assertEq(amount1Min, _amount1Min);
    }

    function test_fuzz_decodeMintParams(
        PositionConfig calldata _config,
        uint256 _liquidity,
        uint128 _amount0Max,
        uint128 _amount1Max,
        address _owner,
        bytes calldata _hookData
    ) public view {
        bytes memory params = abi.encode(_config, _liquidity, _amount0Max, _amount1Max, _owner, _hookData);
        (
            PositionConfig memory config,
            uint256 liquidity,
            uint128 amount0Max,
            uint128 amount1Max,
            address owner,
            bytes memory hookData
        ) = decoder.decodeMintParams(params);

        assertEq(liquidity, _liquidity);
        assertEq(amount0Max, _amount0Max);
        assertEq(amount1Max, _amount1Max);
        assertEq(owner, _owner);
        assertEq(hookData, _hookData);
        _assertEq(_config, config);
    }

    function test_fuzz_decodeSwapExactInParams(IV4Router.ExactInputParams calldata _swapParams) public view {
        bytes memory params = abi.encode(_swapParams);
        IV4Router.ExactInputParams memory swapParams = decoder.decodeSwapExactInParams(params);

        assertEq(Currency.unwrap(swapParams.currencyIn), Currency.unwrap(_swapParams.currencyIn));
        assertEq(swapParams.amountIn, _swapParams.amountIn);
        assertEq(swapParams.amountOutMinimum, _swapParams.amountOutMinimum);
        _assertEq(swapParams.path, _swapParams.path);
    }

    function test_fuzz_decodeSwapExactInSingleParams(IV4Router.ExactInputSingleParams calldata _swapParams)
        public
        view
    {
        bytes memory params = abi.encode(_swapParams);
        IV4Router.ExactInputSingleParams memory swapParams = decoder.decodeSwapExactInSingleParams(params);

        assertEq(swapParams.zeroForOne, _swapParams.zeroForOne);
        assertEq(swapParams.amountIn, _swapParams.amountIn);
        assertEq(swapParams.amountOutMinimum, _swapParams.amountOutMinimum);
        assertEq(swapParams.sqrtPriceLimitX96, _swapParams.sqrtPriceLimitX96);
        assertEq(swapParams.hookData, _swapParams.hookData);
        _assertEq(swapParams.poolKey, _swapParams.poolKey);
    }

    function test_fuzz_decodeSwapExactOutParams(IV4Router.ExactOutputParams calldata _swapParams) public view {
        bytes memory params = abi.encode(_swapParams);
        IV4Router.ExactOutputParams memory swapParams = decoder.decodeSwapExactOutParams(params);

        assertEq(Currency.unwrap(swapParams.currencyOut), Currency.unwrap(_swapParams.currencyOut));
        assertEq(swapParams.amountOut, _swapParams.amountOut);
        assertEq(swapParams.amountInMaximum, _swapParams.amountInMaximum);
        _assertEq(swapParams.path, _swapParams.path);
    }

    function test_fuzz_decodeSwapExactOutSingleParams(IV4Router.ExactOutputSingleParams calldata _swapParams)
        public
        view
    {
        bytes memory params = abi.encode(_swapParams);
        IV4Router.ExactOutputSingleParams memory swapParams = decoder.decodeSwapExactOutSingleParams(params);

        assertEq(swapParams.zeroForOne, _swapParams.zeroForOne);
        assertEq(swapParams.amountOut, _swapParams.amountOut);
        assertEq(swapParams.amountInMaximum, _swapParams.amountInMaximum);
        assertEq(swapParams.sqrtPriceLimitX96, _swapParams.sqrtPriceLimitX96);
        assertEq(swapParams.hookData, _swapParams.hookData);
        _assertEq(swapParams.poolKey, _swapParams.poolKey);
    }

    function test_fuzz_decodeCurrencyAndAddress(Currency _currency, address __address) public view {
        bytes memory params = abi.encode(_currency, __address);
        (Currency currency, address _address) = decoder.decodeCurrencyAndAddress(params);

        assertEq(Currency.unwrap(currency), Currency.unwrap(_currency));
        assertEq(_address, __address);
    }

    function test_fuzz_decodeCurrency(Currency _currency) public view {
        bytes memory params = abi.encode(_currency);
        (Currency currency) = decoder.decodeCurrency(params);

        assertEq(Currency.unwrap(currency), Currency.unwrap(_currency));
    }

    function test_fuzz_decodeCurrencyPair(Currency _currency0, Currency _currency1) public view {
        bytes memory params = abi.encode(_currency0, _currency1);
        (Currency currency0, Currency currency1) = decoder.decodeCurrencyPair(params);

        assertEq(Currency.unwrap(currency0), Currency.unwrap(_currency0));
        assertEq(Currency.unwrap(currency1), Currency.unwrap(_currency1));
    }

    function test_fuzz_decodeCurrencyPairAndAddress(Currency _currency0, Currency _currency1, address __address)
        public
        view
    {
        bytes memory params = abi.encode(_currency0, _currency1, __address);
        (Currency currency0, Currency currency1, address _address) = decoder.decodeCurrencyPairAndAddress(params);

        assertEq(Currency.unwrap(currency0), Currency.unwrap(_currency0));
        assertEq(Currency.unwrap(currency1), Currency.unwrap(_currency1));
        assertEq(_address, __address);
    }

    function test_fuzz_decodeCurrencyAddressAndUint256(Currency _currency, address _addr, uint256 _amount)
        public
        view
    {
        bytes memory params = abi.encode(_currency, _addr, _amount);
        (Currency currency, address addr, uint256 amount) = decoder.decodeCurrencyAddressAndUint256(params);

        assertEq(Currency.unwrap(currency), Currency.unwrap(_currency));
        assertEq(addr, _addr);
        assertEq(amount, _amount);
    }

    function test_fuzz_decodeCurrencyAndUint256(Currency _currency, uint256 _amount) public view {
        bytes memory params = abi.encode(_currency, _amount);
        (Currency currency, uint256 amount) = decoder.decodeCurrencyAndUint256(params);

        assertEq(Currency.unwrap(currency), Currency.unwrap(_currency));
        assertEq(amount, _amount);
    }

    function _assertEq(PathKey[] memory path1, PathKey[] memory path2) internal pure {
        assertEq(path1.length, path2.length);
        for (uint256 i = 0; i < path1.length; i++) {
            assertEq(Currency.unwrap(path1[i].intermediateCurrency), Currency.unwrap(path2[i].intermediateCurrency));
            assertEq(path1[i].fee, path2[i].fee);
            assertEq(path1[i].tickSpacing, path2[i].tickSpacing);
            assertEq(address(path1[i].hooks), address(path2[i].hooks));
            assertEq(path1[i].hookData, path2[i].hookData);
        }
    }

    function _assertEq(PositionConfig memory config1, PositionConfig memory config2) internal pure {
        _assertEq(config1.poolKey, config2.poolKey);
        assertEq(config1.tickLower, config2.tickLower);
        assertEq(config1.tickUpper, config2.tickUpper);
    }

    function _assertEq(PoolKey memory key1, PoolKey memory key2) internal pure {
        assertEq(Currency.unwrap(key1.currency0), Currency.unwrap(key2.currency0));
        assertEq(Currency.unwrap(key1.currency1), Currency.unwrap(key2.currency1));
        assertEq(key1.fee, key2.fee);
        assertEq(key1.tickSpacing, key2.tickSpacing);
        assertEq(address(key1.hooks), address(key2.hooks));
    }
}
