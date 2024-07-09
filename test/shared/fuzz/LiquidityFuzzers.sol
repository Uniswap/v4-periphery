// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
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

        LiquidityRange memory range =
            LiquidityRange({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper});

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(
            lpm.mint.selector, range, uint256(params.liquidityDelta), block.timestamp, recipient, hookData
        );

        Currency[] memory currencies = new Currency[](2);
        currencies[0] = key.currency0;
        currencies[1] = key.currency1;

        int128[] memory result = lpm.modifyLiquidities(calls, currencies);
        BalanceDelta delta = toBalanceDelta(result[0], result[1]);

        uint256 tokenId = lpm.nextTokenId() - 1;
        return (tokenId, params, delta);
    }
}
