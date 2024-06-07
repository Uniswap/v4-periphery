// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {Fuzzers} from "@uniswap/v4-core/src/test/Fuzzers.sol";

import {INonfungiblePositionManager} from "../../../contracts/interfaces/INonfungiblePositionManager.sol";
import {LiquidityRange} from "../../../contracts/types/LiquidityRange.sol";

contract LiquidityFuzzers is Fuzzers {
    function createFuzzyLiquidity(
        INonfungiblePositionManager lpm,
        address recipient,
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        uint160 sqrtPriceX96,
        bytes memory hookData
    ) internal returns (uint256, IPoolManager.ModifyLiquidityParams memory, BalanceDelta) {
        params = Fuzzers.createFuzzyLiquidityParams(key, params, sqrtPriceX96);

        (uint256 tokenId, BalanceDelta delta) = lpm.mint(
            LiquidityRange({key: key, tickLower: params.tickLower, tickUpper: params.tickUpper}),
            uint256(params.liquidityDelta),
            block.timestamp,
            recipient,
            hookData
        );
        return (tokenId, params, delta);
    }
}
