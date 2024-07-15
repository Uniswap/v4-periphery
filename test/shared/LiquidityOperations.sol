// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {NonfungiblePositionManager, Actions} from "../../contracts/NonfungiblePositionManager.sol";
import {LiquidityRange} from "../../contracts/types/LiquidityRange.sol";
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

    function _increaseLiquidity(uint256 tokenId, uint256 liquidityToAdd, bytes memory hookData, bool claims)
        internal
        returns (BalanceDelta)
    {
        (, LiquidityRange memory _range,) = lpm.tokenPositions(tokenId);
        return _increaseLiquidity(_range, tokenId, liquidityToAdd, hookData, claims);
    }

    function _increaseLiquidity(
        LiquidityRange memory _range,
        uint256 tokenId,
        uint256 liquidityToAdd,
        bytes memory hookData,
        bool claims
    ) internal returns (BalanceDelta) {
        // cannot use Planner because it interferes with cheatcodes
        Actions[] memory actions = new Actions[](1);
        actions[0] = Actions.INCREASE;
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(tokenId, liquidityToAdd, hookData, claims);

        planner = planner.finalize(_range); // Close the currencies.
        lpm.modifyLiquidities(abi.encode(planner.actions, planner.params));
    }

    function _decreaseLiquidity(uint256 tokenId, uint256 liquidityToRemove, bytes memory hookData)
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
        // cannot use Planner as it interferes with cheatcodes (prank / expectRevert)
        Actions[] memory actions = new Actions[](1);
        actions[0] = Actions.DECREASE;
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(tokenId, liquidityToRemove, hookData, claims);

        planner = planner.finalize(_range); // Close the currencies.
        bytes[] memory result = lpm.modifyLiquidities(abi.encode(planner.actions, planner.params));
        return abi.decode(result[0], (BalanceDelta));
    }

    function _collect(uint256 tokenId, address recipient, bytes memory hookData) internal returns (BalanceDelta) {
        // Planner.Plan memory planner = Planner.init();
        // planner = planner.add(Actions.DECREASE, abi.encode(tokenId, 0, hookData));
    }

    // do not make external call before unlockAndExecute, allows us to test reverts
    function _collect(
        LiquidityRange memory _range,
        uint256 tokenId,
        address recipient,
        bytes memory hookData,
        bool claims
    ) internal returns (BalanceDelta) {
        // cannot use Planner because it interferes with cheatcodes
        Actions[] memory actions = new Actions[](1);
        actions[0] = Actions.COLLECT;
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(tokenId, recipient, hookData, claims);

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
}
