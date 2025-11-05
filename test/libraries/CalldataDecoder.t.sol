// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {MockCalldataDecoder} from "../mocks/MockCalldataDecoder.sol";
import {PositionConfig} from "../shared/PositionConfig.sol";
import {IV4Router} from "../../src/interfaces/IV4Router.sol";
import {PathKey} from "../../src/libraries/PathKey.sol";
import {CalldataDecoder} from "../../src/libraries/CalldataDecoder.sol";

contract CalldataDecoderTest is Test {
    MockCalldataDecoder decoder;

    function setUp() public {
        decoder = new MockCalldataDecoder();
    }

    function test_fuzz_decodeModifyLiquidityParams(
        uint256 _tokenId,
        uint256 _liquidity,
        uint128 _amount0,
        uint128 _amount1,
        bytes calldata _hookData
    ) public view {
        bytes memory params = abi.encode(_tokenId, _liquidity, _amount0, _amount1, _hookData);
        (uint256 tokenId, uint256 liquidity, uint128 amount0, uint128 amount1, bytes memory hookData) =
            decoder.decodeModifyLiquidityParams(params);

        assertEq(tokenId, _tokenId);
        assertEq(liquidity, _liquidity);
        assertEq(amount0, _amount0);
        assertEq(amount1, _amount1);
        assertEq(hookData, _hookData);
    }

    function test_fuzz_decodeBurnParams(
        uint256 _tokenId,
        uint128 _amount0Min,
        uint128 _amount1Min,
        bytes calldata _hookData
    ) public view {
        bytes memory params = abi.encode(_tokenId, _amount0Min, _amount1Min, _hookData);
        (uint256 tokenId, uint128 amount0Min, uint128 amount1Min, bytes memory hookData) =
            decoder.decodeBurnParams(params);

        assertEq(tokenId, _tokenId);
        assertEq(hookData, _hookData);
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
        bytes memory params = abi.encode(
            _config.poolKey,
            _config.tickLower,
            _config.tickUpper,
            _liquidity,
            _amount0Max,
            _amount1Max,
            _owner,
            _hookData
        );

        (MockCalldataDecoder.MintParams memory mintParams) = decoder.decodeMintParams(params);

        assertEq(mintParams.liquidity, _liquidity);
        assertEq(mintParams.amount0Max, _amount0Max);
        assertEq(mintParams.amount1Max, _amount1Max);
        assertEq(mintParams.owner, _owner);
        assertEq(mintParams.hookData, _hookData);
        _assertEq(mintParams.poolKey, _config.poolKey);
        assertEq(mintParams.tickLower, _config.tickLower);
        assertEq(mintParams.tickUpper, _config.tickUpper);
    }

    function test_fuzz_decodeMintFromDeltasParams(
        PositionConfig calldata _config,
        uint128 _amount0Max,
        uint128 _amount1Max,
        address _owner,
        bytes calldata _hookData
    ) public view {
        bytes memory params = abi.encode(
            _config.poolKey, _config.tickLower, _config.tickUpper, _amount0Max, _amount1Max, _owner, _hookData
        );

        (MockCalldataDecoder.MintFromDeltasParams memory mintParams) = decoder.decodeMintFromDeltasParams(params);

        _assertEq(mintParams.poolKey, _config.poolKey);
        assertEq(mintParams.tickLower, _config.tickLower);
        assertEq(mintParams.tickUpper, _config.tickUpper);
        assertEq(mintParams.amount0Max, _amount0Max);
        assertEq(mintParams.amount1Max, _amount1Max);
        assertEq(mintParams.owner, _owner);
        assertEq(mintParams.hookData, _hookData);
    }

    function test_fuzz_decodeSwapExactInParams(IV4Router.ExactInputParams calldata _swapParams) public view {
        bytes memory params = abi.encode(_swapParams);
        IV4Router.ExactInputParams memory swapParams = decoder.decodeSwapExactInParams(params);

        assertEq(Currency.unwrap(swapParams.currencyIn), Currency.unwrap(_swapParams.currencyIn));
        assertEq(swapParams.amountIn, _swapParams.amountIn);
        assertEq(swapParams.amountOutMinimum, _swapParams.amountOutMinimum);
        _assertEq(swapParams.path, _swapParams.path);
        _assertEq(swapParams.maxHopSlippage, _swapParams.maxHopSlippage);
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
        _assertEq(swapParams.maxHopSlippage, _swapParams.maxHopSlippage);
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
        assertEq(swapParams.hookData, _swapParams.hookData);
        _assertEq(swapParams.poolKey, _swapParams.poolKey);
    }

    function test_fuzz_decodeCurrencyAndAddress(Currency _currency, address __address) public view {
        bytes memory params = abi.encode(_currency, __address);
        (Currency currency, address _address) = decoder.decodeCurrencyAndAddress(params);

        assertEq(Currency.unwrap(currency), Currency.unwrap(_currency));
        assertEq(_address, __address);
    }

    function test_decodeCurrencyAndAddress_outOutBounds() public {
        Currency currency = Currency.wrap(address(0x12341234));
        address addy = address(0x23453456);

        bytes memory params = abi.encode(currency, addy);
        bytes memory invalidParams = _removeFinalByte(params);
        assertEq(invalidParams.length, params.length - 1);

        vm.expectRevert(CalldataDecoder.SliceOutOfBounds.selector);
        decoder.decodeCurrencyAndAddress(invalidParams);
    }

    function test_fuzz_decodeCurrency(Currency _currency) public view {
        bytes memory params = abi.encode(_currency);
        (Currency currency) = decoder.decodeCurrency(params);

        assertEq(Currency.unwrap(currency), Currency.unwrap(_currency));
    }

    function test_decodeCurrency_outOutBounds() public {
        Currency currency = Currency.wrap(address(0x12341234));

        bytes memory params = abi.encode(currency);
        bytes memory invalidParams = _removeFinalByte(params);
        assertEq(invalidParams.length, params.length - 1);

        vm.expectRevert(CalldataDecoder.SliceOutOfBounds.selector);
        decoder.decodeCurrency(invalidParams);
    }

    function test_fuzz_decodeActionsRouterParams(bytes memory _actions, bytes[] memory _actionParams) public view {
        bytes memory params = abi.encode(_actions, _actionParams);
        (bytes memory actions, bytes[] memory actionParams) = decoder.decodeActionsRouterParams(params);

        assertEq(actions, _actions);
        for (uint256 i = 0; i < _actionParams.length; i++) {
            assertEq(actionParams[i], _actionParams[i]);
        }
    }

    function test_decodeActionsRouterParams_sliceOutOfBounds() public {
        // create actions and parameters
        bytes memory _actions = hex"12345678";
        bytes[] memory _actionParams = new bytes[](4);
        _actionParams[0] = hex"11111111";
        _actionParams[1] = hex"22";
        _actionParams[2] = hex"3333333333333333";
        _actionParams[3] = hex"4444444444444444444444444444444444444444444444444444444444444444";

        bytes memory params = abi.encode(_actions, _actionParams);

        bytes memory invalidParams = _removeFinalByte(params);

        assertEq(invalidParams.length, params.length - 1);

        vm.expectRevert(CalldataDecoder.SliceOutOfBounds.selector);
        decoder.decodeActionsRouterParams(invalidParams);
    }

    function test_decodeActionsRouterParams_emptyParams() public view {
        // create actions and parameters
        bytes memory _actions = hex"";
        bytes[] memory _actionParams = new bytes[](0);

        bytes memory params = abi.encode(_actions, _actionParams);

        (bytes memory actions, bytes[] memory actionParams) = decoder.decodeActionsRouterParams(params);
        assertEq(actions, _actions);
        assertEq(actionParams.length, _actionParams.length);
        assertEq(actionParams.length, 0);
    }

    function test_fuzz_decodeCurrencyPair(Currency _currency0, Currency _currency1) public view {
        bytes memory params = abi.encode(_currency0, _currency1);
        (Currency currency0, Currency currency1) = decoder.decodeCurrencyPair(params);

        assertEq(Currency.unwrap(currency0), Currency.unwrap(_currency0));
        assertEq(Currency.unwrap(currency1), Currency.unwrap(_currency1));
    }

    function test_decodeCurrencyPair_outOutBounds() public {
        Currency currency = Currency.wrap(address(0x12341234));
        Currency currency2 = Currency.wrap(address(0x56785678));

        bytes memory params = abi.encode(currency, currency2);
        bytes memory invalidParams = _removeFinalByte(params);
        assertEq(invalidParams.length, params.length - 1);

        vm.expectRevert(CalldataDecoder.SliceOutOfBounds.selector);
        decoder.decodeCurrencyPair(invalidParams);
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

    function test_decodeCurrencyPairAndAddress_outOutBounds() public {
        Currency currency = Currency.wrap(address(0x12341234));
        Currency currency2 = Currency.wrap(address(0x56785678));
        address addy = address(0x23453456);

        bytes memory params = abi.encode(currency, currency2, addy);
        bytes memory invalidParams = _removeFinalByte(params);
        assertEq(invalidParams.length, params.length - 1);

        vm.expectRevert(CalldataDecoder.SliceOutOfBounds.selector);
        decoder.decodeCurrencyPairAndAddress(invalidParams);
    }

    function test_fuzz_decodeCurrencyAddressAndUint256(Currency _currency, address _addr, uint256 _amount) public view {
        bytes memory params = abi.encode(_currency, _addr, _amount);
        (Currency currency, address addr, uint256 amount) = decoder.decodeCurrencyAddressAndUint256(params);

        assertEq(Currency.unwrap(currency), Currency.unwrap(_currency));
        assertEq(addr, _addr);
        assertEq(amount, _amount);
    }

    function test_decodeCurrencyAddressAndUint256_outOutBounds() public {
        uint256 value = 12345678;
        Currency currency = Currency.wrap(address(0x12341234));
        address addy = address(0x67896789);

        bytes memory params = abi.encode(currency, addy, value);
        bytes memory invalidParams = _removeFinalByte(params);
        assertEq(invalidParams.length, params.length - 1);

        vm.expectRevert(CalldataDecoder.SliceOutOfBounds.selector);
        decoder.decodeCurrencyAddressAndUint256(invalidParams);
    }

    function test_fuzz_decodeCurrencyAndUint256(Currency _currency, uint256 _amount) public view {
        bytes memory params = abi.encode(_currency, _amount);
        (Currency currency, uint256 amount) = decoder.decodeCurrencyAndUint256(params);

        assertEq(Currency.unwrap(currency), Currency.unwrap(_currency));
        assertEq(amount, _amount);
    }

    function test_decodeCurrencyAndUint256_outOutBounds() public {
        uint256 value = 12345678;
        Currency currency = Currency.wrap(address(0x12341234));

        bytes memory params = abi.encode(currency, value);
        bytes memory invalidParams = _removeFinalByte(params);
        assertEq(invalidParams.length, params.length - 1);

        vm.expectRevert(CalldataDecoder.SliceOutOfBounds.selector);
        decoder.decodeCurrencyAndUint256(invalidParams);
    }

    function test_fuzz_decodeIncreaseLiquidityFromAmountsParams(
        uint256 _tokenId,
        uint128 _amount0Max,
        uint128 _amount1Max,
        bytes calldata _hookData
    ) public view {
        bytes memory params = abi.encode(_tokenId, _amount0Max, _amount1Max, _hookData);

        (uint256 tokenId, uint128 amount0Max, uint128 amount1Max, bytes memory hookData) =
            decoder.decodeIncreaseLiquidityFromDeltasParams(params);
        assertEq(_tokenId, tokenId);
        assertEq(_amount0Max, amount0Max);
        assertEq(_amount1Max, amount1Max);
        assertEq(_hookData, hookData);
    }

    function test_fuzz_decodeUint256(uint256 _amount) public view {
        bytes memory params = abi.encode(_amount);
        uint256 amount = decoder.decodeUint256(params);

        assertEq(amount, _amount);
    }

    function test_decodeUint256_outOutBounds() public {
        uint256 value = 12345678;

        bytes memory params = abi.encode(value);
        bytes memory invalidParams = _removeFinalByte(params);
        assertEq(invalidParams.length, params.length - 1);

        vm.expectRevert(CalldataDecoder.SliceOutOfBounds.selector);
        decoder.decodeUint256(invalidParams);
    }

    function test_fuzz_decodeCurrencyUint256AndBool(Currency _currency, uint256 _amount, bool _boolean) public view {
        bytes memory params = abi.encode(_currency, _amount, _boolean);
        (Currency currency, uint256 amount, bool boolean) = decoder.decodeCurrencyUint256AndBool(params);

        assertEq(Currency.unwrap(currency), Currency.unwrap(_currency));
        assertEq(amount, _amount);
        assertEq(boolean, _boolean);
    }

    function test_decodeCurrencyUint256AndBool_outOutBounds() public {
        uint256 value = 12345678;
        Currency currency = Currency.wrap(address(0x12341234));
        bool boolean = true;

        bytes memory params = abi.encode(currency, value, boolean);
        bytes memory invalidParams = _removeFinalByte(params);
        assertEq(invalidParams.length, params.length - 1);

        vm.expectRevert(CalldataDecoder.SliceOutOfBounds.selector);
        decoder.decodeCurrencyUint256AndBool(invalidParams);
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

    function _assertEq(uint256[] memory a, uint256[] memory b) internal pure {
        assertEq(a.length, b.length);
        for (uint256 i = 0; i < a.length; i++) {
            assertEq(a[i], b[i]);
        }
    }

    function _assertEq(PoolKey memory key1, PoolKey memory key2) internal pure {
        assertEq(Currency.unwrap(key1.currency0), Currency.unwrap(key2.currency0));
        assertEq(Currency.unwrap(key1.currency1), Currency.unwrap(key2.currency1));
        assertEq(key1.fee, key2.fee);
        assertEq(key1.tickSpacing, key2.tickSpacing);
        assertEq(address(key1.hooks), address(key2.hooks));
    }

    function _removeFinalByte(bytes memory params) internal pure returns (bytes memory result) {
        result = new bytes(params.length - 1);
        // dont copy the final byte
        for (uint256 i = 0; i < params.length - 2; i++) {
            result[i] = params[i];
        }
    }
}
