// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {NonfungiblePositionManager, Actions} from "../../contracts/NonfungiblePositionManager.sol";
import {LiquidityRange} from "../../contracts/types/LiquidityRange.sol";
import {Planner} from "../utils/Planner.sol";

contract LiquidityOperations {
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

    function _increaseLiquidity(uint256 tokenId, uint256 liquidityToAdd, bytes memory hookData, bool claims) internal {
        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.INCREASE, abi.encode(tokenId, liquidityToAdd, hookData, claims));

        (, LiquidityRange memory _range) = lpm.tokenPositions(tokenId);

        planner = planner.finalize(_range); // Close the currencies.
        lpm.modifyLiquidities(abi.encode(planner.actions, planner.params));
    }

    function _decreaseLiquidity(uint256 tokenId, uint256 liquidityToRemove, bytes memory hookData, bool claims)
        internal
        returns (BalanceDelta)
    {
        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.DECREASE, abi.encode(tokenId, liquidityToRemove, hookData, claims));

        (, LiquidityRange memory _range) = lpm.tokenPositions(tokenId);

        planner = planner.finalize(_range); // Close the currencies.
        bytes[] memory result = lpm.modifyLiquidities(abi.encode(planner.actions, planner.params));
        return abi.decode(result[0], (BalanceDelta));
    }

    function _collect(uint256 tokenId, address recipient, bytes memory hookData, bool claims)
        internal
        returns (BalanceDelta)
    {
        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.DECREASE, abi.encode(tokenId, 0, hookData, claims));

        (, LiquidityRange memory _range) = lpm.tokenPositions(tokenId);

        planner = planner.finalize(_range); // Close the currencies.

        bytes[] memory result = lpm.modifyLiquidities(planner.zip());
        return abi.decode(result[0], (BalanceDelta));
    }

    function _burn(uint256 tokenId) internal {
        Currency[] memory currencies = new Currency[](0);
        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.BURN, abi.encode(tokenId));
        // No close needed on burn.
        lpm.modifyLiquidities(planner.zip());
    }
}
