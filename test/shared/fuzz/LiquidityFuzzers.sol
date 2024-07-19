// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Fuzzers} from "@uniswap/v4-core/src/test/Fuzzers.sol";

import {INonfungiblePositionManager, Actions} from "../../../src/interfaces/INonfungiblePositionManager.sol";
import {LiquidityRange} from "../../../src/types/LiquidityRange.sol";
import {Planner} from "../../utils/Planner.sol";

contract LiquidityFuzzers is Fuzzers {
    using Planner for Planner.Plan;

    function addFuzzyLiquidity(
        INonfungiblePositionManager lpm,
        address recipient,
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        uint160 sqrtPriceX96,
        bytes memory hookData
    ) internal returns (uint256, IPoolManager.ModifyLiquidityParams memory) {
        params = Fuzzers.createFuzzyLiquidityParams(key, params, sqrtPriceX96);
        LiquidityRange memory range =
            LiquidityRange({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});

        Planner.Plan memory planner =
            Planner.init().add(Actions.MINT, abi.encode(range, uint256(params.liquidityDelta), recipient, hookData));

        bytes memory calls = planner.finalize(range.poolKey);
        lpm.modifyLiquidities(calls, block.timestamp + 1);

        uint256 tokenId = lpm.nextTokenId() - 1;
        return (tokenId, params);
    }
}
