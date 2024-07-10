// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {NonfungiblePositionManager} from "../../contracts/NonfungiblePositionManager.sol";
import {LiquidityRange} from "../../contracts/types/LiquidityRange.sol";

contract LiquidityOperations {
    Vm internal constant _vm1 = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
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

        (, LiquidityRange memory _range,) = lpm.tokenPositions(tokenId);
        return _increaseLiquidity(_range, tokenId, liquidityToAdd, hookData, claims);
    }

    function _increaseLiquidity(
        LiquidityRange memory _range,
        uint256 tokenId,
        uint256 liquidityToAdd,
        bytes memory hookData,
        bool claims
    ) internal {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(lpm.increaseLiquidity.selector, tokenId, liquidityToAdd, hookData, claims);

        Currency[] memory currencies = new Currency[](2);
        currencies[0] = _range.poolKey.currency0;
        currencies[1] = _range.poolKey.currency1;
        lpm.modifyLiquidities(calls, currencies);
    }

    function _decreaseLiquidity(uint256 tokenId, uint256 liquidityToRemove, bytes memory hookData, bool claims)
        internal
        returns (BalanceDelta)
    {
        (, LiquidityRange memory _range,) = lpm.tokenPositions(tokenId);

        return _decreaseLiquidity(_range, tokenId, liquidityToRemove, hookData, claims);
    }

    // do not make external call before unlockAndExecute, allows us to test reverts
    function _decreaseLiquidity(
        LiquidityRange memory _range,
        uint256 tokenId,
        uint256 liquidityToRemove,
        bytes memory hookData,
        bool claims
    ) internal returns (BalanceDelta) {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(lpm.decreaseLiquidity.selector, tokenId, liquidityToRemove, hookData, claims);

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
        (, LiquidityRange memory _range,) = lpm.tokenPositions(tokenId);
        return _collect(_range, tokenId, recipient, hookData, claims);
    }

    // do not make external call before unlockAndExecute, allows us to test reverts
    function _collect(
        LiquidityRange memory _range,
        uint256 tokenId,
        address recipient,
        bytes memory hookData,
        bool claims
    ) internal returns (BalanceDelta) {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(lpm.collect.selector, tokenId, recipient, hookData, claims);

        Currency[] memory currencies = new Currency[](2);
        currencies[0] = _range.poolKey.currency0;
        currencies[1] = _range.poolKey.currency1;

        int128[] memory result = lpm.modifyLiquidities(calls, currencies);
        return toBalanceDelta(result[0], result[1]);
    }

    // TODO: organize somewhere else, or rename this file to NFTLiquidityHelpers?
    function _permit(address signer, uint256 privateKey, uint256 tokenId, address operator) internal {
        bytes32 digest = lpm.getDigest(operator, tokenId, lpm.nonce(signer), block.timestamp + 1);

        (uint8 v, bytes32 r, bytes32 s) = _vm1.sign(privateKey, digest);

        _vm1.prank(signer);
        lpm.permit(operator, tokenId, block.timestamp + 1, v, r, s);
    }
}
