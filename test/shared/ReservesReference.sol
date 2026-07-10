// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

library ReservesReference {
    struct Position {
        int24 lower;
        int24 upper;
        uint128 liquidity;
    }

    function aggregate(uint160 sqrtPriceX96, int24 currentTick, Position[] memory positions)
        internal
        pure
        returns (uint256 amount0, uint256 amount1, uint128 activeLiquidity)
    {
        int24[] memory ticks = new int24[](positions.length * 2);
        for (uint256 i; i < positions.length; i++) {
            ticks[i * 2] = positions[i].lower;
            ticks[i * 2 + 1] = positions[i].upper;
        }
        _sort(ticks);

        uint128 running;
        bool hasPrevious;
        int24 previous;
        uint256 index;
        while (index < ticks.length) {
            int24 tick = ticks[index];
            int256 net;
            while (index < ticks.length && ticks[index] == tick) index++;
            for (uint256 i; i < positions.length; i++) {
                if (positions[i].lower == tick) net += int256(uint256(positions[i].liquidity));
                if (positions[i].upper == tick) net -= int256(uint256(positions[i].liquidity));
            }
            if (net == 0) continue;

            if (hasPrevious) {
                if (currentTick >= previous && currentTick < tick) activeLiquidity = running;
                (uint256 interval0, uint256 interval1) = _amounts(sqrtPriceX96, currentTick, previous, tick, running);
                amount0 += interval0;
                amount1 += interval1;
            }
            running = uint128(uint256(int256(uint256(running)) + net));
            previous = tick;
            hasPrevious = true;
        }
        assert(running == 0);
    }

    function _amounts(uint160 sqrtPriceX96, int24 currentTick, int24 tickA, int24 tickB, uint128 liquidity)
        private
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (liquidity == 0) return (0, 0);
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickA);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickB);
        if (currentTick < tickA) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liquidity, false);
        } else if (currentTick < tickB) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtB, liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtPriceX96, liquidity, false);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liquidity, false);
        }
    }

    function _sort(int24[] memory values) private pure {
        for (uint256 i = 1; i < values.length; i++) {
            int24 value = values[i];
            uint256 j = i;
            while (j > 0 && values[j - 1] > value) {
                values[j] = values[j - 1];
                j--;
            }
            values[j] = value;
        }
    }
}
