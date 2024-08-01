// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {MockCalldataDecoder} from "../mocks/MockCalldataDecoder.sol";
import {PositionConfig} from "../../src/libraries/PositionConfig.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

contract CalldataDecoderTest is Test {
    MockCalldataDecoder decoder;

    function setUp() public {
        decoder = new MockCalldataDecoder();
    }

    function test_fuzz_decodeModifyLiquidityParams(
        uint256 _tokenId,
        PositionConfig calldata _config,
        uint256 _liquidity,
        bytes calldata _hookData
    ) public view {
        bytes memory params = abi.encode(_tokenId, _config, _liquidity, _hookData);
        (uint256 tokenId, PositionConfig memory config, uint256 liquidity, bytes memory hookData) =
            decoder.decodeModifyLiquidityParams(params);

        assertEq(tokenId, _tokenId);
        assertEq(liquidity, _liquidity);
        assertEq(hookData, _hookData);
        _assertEq(_config, config);
    }

    function test_fuzz_decodeBurnParams(uint256 _tokenId, PositionConfig calldata _config, bytes calldata _hookData)
        public
        view
    {
        bytes memory params = abi.encode(_tokenId, _config, _hookData);
        (uint256 tokenId, PositionConfig memory config, bytes memory hookData) = decoder.decodeBurnParams(params);

        assertEq(tokenId, _tokenId);
        assertEq(hookData, _hookData);
        _assertEq(_config, config);
    }

    function test_fuzz_decodeMintParams(
        PositionConfig calldata _config,
        uint256 _liquidity,
        address _owner,
        bytes calldata _hookData
    ) public view {
        bytes memory params = abi.encode(_config, _liquidity, _owner, _hookData);
        (PositionConfig memory config, uint256 liquidity, address owner, bytes memory hookData) =
            decoder.decodeMintParams(params);

        assertEq(liquidity, _liquidity);
        assertEq(owner, _owner);
        assertEq(hookData, _hookData);
        _assertEq(_config, config);
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

    function test_fuzz_decodeCurrencyAndAddress(Currency _currency, uint256 _amount) public view {
        bytes memory params = abi.encode(_currency, _amount);
        (Currency currency, uint256 amount) = decoder.decodeCurrencyAndUint256(params);

        assertEq(Currency.unwrap(currency), Currency.unwrap(_currency));
        assertEq(amount, _amount);
    }

    function _assertEq(PositionConfig memory config1, PositionConfig memory config2) internal pure {
        assertEq(Currency.unwrap(config1.poolKey.currency0), Currency.unwrap(config2.poolKey.currency0));
        assertEq(Currency.unwrap(config1.poolKey.currency1), Currency.unwrap(config2.poolKey.currency1));
        assertEq(config1.poolKey.fee, config2.poolKey.fee);
        assertEq(config1.poolKey.tickSpacing, config2.poolKey.tickSpacing);
        assertEq(address(config1.poolKey.hooks), address(config2.poolKey.hooks));
        assertEq(config1.tickLower, config2.tickLower);
        assertEq(config1.tickUpper, config2.tickUpper);
    }
}
