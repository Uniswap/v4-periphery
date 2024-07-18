// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {NonfungiblePositionManager, Actions} from "../../src/NonfungiblePositionManager.sol";
import {LiquidityRange} from "../../src/types/LiquidityRange.sol";
import {Planner} from "../utils/Planner.sol";

contract LiquidityOperations {
    Vm internal constant _vm1 = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    NonfungiblePositionManager lpm;

    using Planner for Planner.Plan;

    function _mint(
        LiquidityRange memory _range,
        uint256 liquidity,
        uint256 deadline,
        address recipient,
        bytes memory hookData
    ) internal returns (BalanceDelta) {
        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.MINT, abi.encode(_range, liquidity, deadline, recipient, hookData));
        planner = planner.finalize(_range); // Close the currencies.

        bytes[] memory result = lpm.modifyLiquidities(planner.zip());
        return abi.decode(result[0], (BalanceDelta));
    }

    // we overloaded this function because vm.prank was hitting .tokenPositions()
    // TODO: now that vm.prank is hitting Planner, we can probably consolidate to a single function
    function _increaseLiquidity(uint256 tokenId, uint256 liquidityToAdd, bytes memory hookData)
        internal
        returns (BalanceDelta)
    {
        (, LiquidityRange memory _range,) = lpm.tokenPositions(tokenId);
        return _increaseLiquidity(_range, tokenId, liquidityToAdd, hookData);
    }

    function _increaseLiquidity(
        LiquidityRange memory _range,
        uint256 tokenId,
        uint256 liquidityToAdd,
        bytes memory hookData
    ) internal returns (BalanceDelta) {
        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.INCREASE, abi.encode(tokenId, liquidityToAdd, hookData));

        planner = planner.finalize(_range); // Close the currencies.
        bytes[] memory result = lpm.modifyLiquidities(planner.zip());
        return abi.decode(result[0], (BalanceDelta));
    }

    function _decreaseLiquidity(uint256 tokenId, uint256 liquidityToRemove, bytes memory hookData)
        internal
        returns (BalanceDelta)
    {
        (, LiquidityRange memory _range,) = lpm.tokenPositions(tokenId);

        return _decreaseLiquidity(_range, tokenId, liquidityToRemove, hookData);
    }

    // do not make external call before unlockAndExecute, allows us to test reverts
    function _decreaseLiquidity(
        LiquidityRange memory _range,
        uint256 tokenId,
        uint256 liquidityToRemove,
        bytes memory hookData
    ) internal returns (BalanceDelta) {
        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.DECREASE, abi.encode(tokenId, liquidityToRemove, hookData));

        planner = planner.finalize(_range); // Close the currencies.
        bytes[] memory result = lpm.modifyLiquidities(planner.zip());
        return abi.decode(result[0], (BalanceDelta));
    }

    function _collect(uint256 tokenId, address recipient, bytes memory hookData) internal returns (BalanceDelta) {
        (, LiquidityRange memory _range,) = lpm.tokenPositions(tokenId);
        return _collect(_range, tokenId, recipient, hookData);
    }

    // do not make external call before unlockAndExecute, allows us to test reverts
    function _collect(LiquidityRange memory _range, uint256 tokenId, address recipient, bytes memory hookData)
        internal
        returns (BalanceDelta)
    {
        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.DECREASE, abi.encode(tokenId, 0, hookData));

        planner = planner.finalize(_range); // Close the currencies.

        bytes[] memory result = lpm.modifyLiquidities(planner.zip());
        return abi.decode(result[0], (BalanceDelta));
    }

    function _burn(uint256 tokenId) internal {
        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.BURN, abi.encode(tokenId));
        // No close needed on burn.
        lpm.modifyLiquidities(planner.zip());
    }

    // TODO: organize somewhere else, or rename this file to NFTLiquidityHelpers?
    function _permit(address signer, uint256 privateKey, uint256 tokenId, address operator, uint256 nonce) internal {
        bytes32 digest = lpm.getDigest(operator, tokenId, 1, block.timestamp + 1);

        (uint8 v, bytes32 r, bytes32 s) = _vm1.sign(privateKey, digest);

        _vm1.prank(signer);
        lpm.permit(operator, tokenId, block.timestamp + 1, nonce, v, r, s);
    }

    // Helper functions for getting encoded calldata for .modifyLiquidities
    function getIncreaseEncoded(uint256 tokenId, uint256 liquidityToAdd, bytes memory hookData)
        internal
        view
        returns (bytes memory)
    {
        (, LiquidityRange memory _range,) = lpm.tokenPositions(tokenId);
        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.INCREASE, abi.encode(tokenId, liquidityToAdd, hookData));
        planner = planner.finalize(_range);
        return planner.zip();
    }

    function getDecreaseEncoded(uint256 tokenId, uint256 liquidityToRemove, bytes memory hookData)
        internal
        view
        returns (bytes memory)
    {
        (, LiquidityRange memory _range,) = lpm.tokenPositions(tokenId);
        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.DECREASE, abi.encode(tokenId, liquidityToRemove, hookData));
        planner = planner.finalize(_range);
        return planner.zip();
    }

    function getCollectEncoded(uint256 tokenId, address recipient, bytes memory hookData)
        internal
        view
        returns (bytes memory)
    {
        (, LiquidityRange memory _range,) = lpm.tokenPositions(tokenId);
        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.DECREASE, abi.encode(tokenId, 0, hookData));

        // TODO: allow recipient when supported on CLOSE_CURRENCY?
        planner = planner.add(Actions.CLOSE_CURRENCY, abi.encode(_range.poolKey.currency0));
        planner = planner.add(Actions.CLOSE_CURRENCY, abi.encode(_range.poolKey.currency1));
        return planner.zip();
    }
}
