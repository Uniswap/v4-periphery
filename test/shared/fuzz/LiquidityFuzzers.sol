// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Fuzzers} from "@uniswap/v4-core/src/test/Fuzzers.sol";

import {IPositionManager, Actions} from "../../../src/interfaces/IPositionManager.sol";
import {PoolPosition} from "../../../src/libraries/PoolPosition.sol";
import {Planner} from "../../utils/Planner.sol";

contract LiquidityFuzzers is Fuzzers {
    using Planner for Planner.Plan;

    function addFuzzyLiquidity(
        IPositionManager lpm,
        address recipient,
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        uint160 sqrtPriceX96,
        bytes memory hookData
    ) internal returns (uint256, IPoolManager.ModifyLiquidityParams memory) {
        params = Fuzzers.createFuzzyLiquidityParams(key, params, sqrtPriceX96);
        PoolPosition memory poolPos =
            PoolPosition({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});

        Planner.Plan memory planner =
            Planner.init().add(Actions.MINT, abi.encode(poolPos, uint256(params.liquidityDelta), recipient, hookData));

        bytes memory calls = planner.finalize(poolPos.poolKey);
        lpm.modifyLiquidities(calls, block.timestamp + 1);

        uint256 tokenId = lpm.nextTokenId() - 1;
        return (tokenId, params);
    }
}
