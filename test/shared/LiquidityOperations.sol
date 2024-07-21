// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {PositionManager, Actions} from "../../src/PositionManager.sol";
import {PoolPosition} from "../../src/libraries/PoolPosition.sol";
import {Planner} from "../utils/Planner.sol";

abstract contract LiquidityOperations is CommonBase {
    using Planner for Planner.Plan;

    PositionManager lpm;

    uint256 _deadline = block.timestamp + 1;

    function mint(PoolPosition memory poolPos, uint256 liquidity, address recipient, bytes memory hookData)
        internal
        returns (BalanceDelta)
    {
        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.MINT, abi.encode(poolPos, liquidity, recipient, hookData));

        bytes memory calls = planner.finalize(poolPos.poolKey);
        bytes[] memory result = lpm.modifyLiquidities(calls, _deadline);
        return abi.decode(result[0], (BalanceDelta));
    }

    function increaseLiquidity(
        uint256 tokenId,
        PoolPosition memory poolPos,
        uint256 liquidityToAdd,
        bytes memory hookData
    ) internal returns (BalanceDelta) {
        bytes memory calls = getIncreaseEncoded(tokenId, poolPos, liquidityToAdd, hookData);
        bytes[] memory result = lpm.modifyLiquidities(calls, _deadline);
        return abi.decode(result[0], (BalanceDelta));
    }

    // do not make external call before unlockAndExecute, allows us to test reverts
    function decreaseLiquidity(
        uint256 tokenId,
        PoolPosition memory poolPos,
        uint256 liquidityToRemove,
        bytes memory hookData
    ) internal returns (BalanceDelta) {
        bytes memory calls = getDecreaseEncoded(tokenId, poolPos, liquidityToRemove, hookData);
        bytes[] memory result = lpm.modifyLiquidities(calls, _deadline);
        return abi.decode(result[0], (BalanceDelta));
    }

    function collect(uint256 tokenId, PoolPosition memory poolPos, bytes memory hookData)
        internal
        returns (BalanceDelta)
    {
        bytes memory calls = getCollectEncoded(tokenId, poolPos, hookData);
        bytes[] memory result = lpm.modifyLiquidities(calls, _deadline);
        return abi.decode(result[0], (BalanceDelta));
    }

    function burn(uint256 tokenId) internal {
        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.BURN, abi.encode(tokenId));
        // No close needed on burn.
        bytes memory actions = planner.encode();
        lpm.modifyLiquidities(actions, _deadline);
    }

    // Helper functions for getting encoded calldata for .modifyLiquidities
    function getIncreaseEncoded(
        uint256 tokenId,
        PoolPosition memory poolPos,
        uint256 liquidityToAdd,
        bytes memory hookData
    ) internal pure returns (bytes memory) {
        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.INCREASE, abi.encode(tokenId, poolPos, liquidityToAdd, hookData));
        return planner.finalize(poolPos.poolKey);
    }

    function getDecreaseEncoded(
        uint256 tokenId,
        PoolPosition memory poolPos,
        uint256 liquidityToRemove,
        bytes memory hookData
    ) internal pure returns (bytes memory) {
        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.DECREASE, abi.encode(tokenId, poolPos, liquidityToRemove, hookData));
        return planner.finalize(poolPos.poolKey);
    }

    function getCollectEncoded(uint256 tokenId, PoolPosition memory poolPos, bytes memory hookData)
        internal
        pure
        returns (bytes memory)
    {
        Planner.Plan memory planner = Planner.init();
        planner = planner.add(Actions.DECREASE, abi.encode(tokenId, poolPos, 0, hookData));
        return planner.finalize(poolPos.poolKey);
    }
}
