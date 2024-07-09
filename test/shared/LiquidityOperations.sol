// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {NonfungiblePositionManager} from "../../contracts/NonfungiblePositionManager.sol";
import {LiquidityRange} from "../../contracts/types/LiquidityRange.sol";

contract LiquidityOperations {
    NonfungiblePositionManager lpm;

    function _mint(
        LiquidityRange memory _range,
        uint256 liquidity,
        uint256 deadline,
        address recipient,
        bytes memory hookData
    ) internal returns (BalanceDelta) {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(lpm.mint.selector, _range, liquidity, deadline, recipient, hookData);
        Currency[] memory currencies = new Currency[](2);
        currencies[0] = _range.poolKey.currency0;
        currencies[1] = _range.poolKey.currency1;
        int128[] memory result = lpm.modifyLiquidities(calls, currencies);
        return toBalanceDelta(result[0], result[1]);
    }

    function _increaseLiquidity(uint256 tokenId, uint256 liquidityToAdd, bytes memory hookData, bool claims) internal {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(lpm.increaseLiquidity.selector, tokenId, liquidityToAdd, hookData, claims);

        (, LiquidityRange memory _range) = lpm.tokenPositions(tokenId);

        Currency[] memory currencies = new Currency[](2);
        currencies[0] = _range.poolKey.currency0;
        currencies[1] = _range.poolKey.currency1;
        lpm.modifyLiquidities(calls, currencies);
    }

    function _decreaseLiquidity(uint256 tokenId, uint256 liquidityToRemove, bytes memory hookData, bool claims)
        internal
        returns (BalanceDelta)
    {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(lpm.decreaseLiquidity.selector, tokenId, liquidityToRemove, hookData, claims);

        (, LiquidityRange memory _range) = lpm.tokenPositions(tokenId);

        Currency[] memory currencies = new Currency[](2);
        currencies[0] = _range.poolKey.currency0;
        currencies[1] = _range.poolKey.currency1;
        int128[] memory result = lpm.modifyLiquidities(calls, currencies);
        return toBalanceDelta(result[0], result[1]);
    }

    function _collect(uint256 tokenId, address recipient, bytes memory hookData, bool claims)
        internal
        returns (BalanceDelta)
    {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(lpm.collect.selector, tokenId, recipient, hookData, claims);

        (, LiquidityRange memory _range) = lpm.tokenPositions(tokenId);

        Currency[] memory currencies = new Currency[](2);
        currencies[0] = _range.poolKey.currency0;
        currencies[1] = _range.poolKey.currency1;
        int128[] memory result = lpm.modifyLiquidities(calls, currencies);
        return toBalanceDelta(result[0], result[1]);
    }
}
