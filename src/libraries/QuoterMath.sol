// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IQuoter} from "../interfaces/IQuoter.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {LiquidityMath} from "@uniswap/v4-core/src/libraries/LiquidityMath.sol";
import {PoolTickBitmap} from "./PoolTickBitmap.sol";
import {Slot0, Slot0Library} from "@uniswap/v4-core/src/types/Slot0.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

library QuoterMath {
    using SafeCast for uint256;
    using SafeCast for int256;

    using Slot0Library for Slot0;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    struct Slot0Struct {
        // the current price
        uint160 sqrtPriceX96;
        // the current tick
        int24 tick;
        // tick spacing
        int24 tickSpacing;
    }

    // used for packing under the stack limit
    struct QuoteParams {
        bool zeroForOne;
        bool exactInput;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function fillSlot0(IPoolManager poolManager, PoolKey calldata poolKey)
        private
        view
        returns (Slot0Struct memory slot0)
    {
        (slot0.sqrtPriceX96, slot0.tick,,) = poolManager.getSlot0(poolKey.toId());
        slot0.tickSpacing = poolKey.tickSpacing;
        return slot0;
    }

    struct SwapCache {
        // the protocol fee for the input token
        uint8 feeProtocol;
        // liquidity at the beginning of the swap
        uint128 liquidityStart;
        // the timestamp of the current block
        uint32 blockTimestamp;
        // the current value of the tick accumulator, computed only if we cross an initialized tick
        int56 tickCumulative;
        // the current value of seconds per liquidity accumulator, computed only if we cross an initialized tick
        uint160 secondsPerLiquidityCumulativeX128;
        // whether we've computed and cached the above two accumulators
        bool computedLatestObservation;
    }

    // the top level state of the swap, the results of which are recorded in storage at the end
    struct SwapState {
        // the amount remaining to be swapped in/out of the input/output asset
        int256 amountSpecifiedRemaining;
        // the amount already swapped out/in of the output/input asset
        int256 amountCalculated;
        // current sqrt(price)
        uint160 sqrtPriceX96;
        // the tick associated with the current price
        int24 tick;
        // the global fee growth of the input token
        uint256 feeGrowthGlobalX128;
        // amount of input token paid as protocol fee
        uint128 protocolFee;
        // the current liquidity in range
        uint128 liquidity;
    }

    struct StepComputations {
        // the price at the beginning of the step
        uint160 sqrtPriceStartX96;
        // the next tick to swap to from the current tick in the swap direction
        int24 tickNext;
        // whether tickNext is initialized or not
        bool initialized;
        // sqrt(price) for the next tick (1/0)
        uint160 sqrtPriceNextX96;
        // how much is being swapped in in this step
        uint256 amountIn;
        // how much is being swapped out
        uint256 amountOut;
        // how much fee is being paid in
        uint256 feeAmount;
    }

    /// @notice Utility function called by the quote functions to
    /// calculate the amounts in/out for a hookless v4 swap
    /// @param poolManager the Uniswap v4 pool manager
    /// @param poolKey The poolKey identifying the pool traded against
    /// @param swapParams The parameters used for the swap
    /// @return amount0 the amount of token0 sent in or out of the pool
    /// @return amount1 the amount of token1 sent in or out of the pool
    /// @return sqrtPriceAfterX96 the price of the pool after the swap
    /// @return initializedTicksCrossed the number of initialized ticks LOADED IN
    function quote(IPoolManager poolManager, PoolKey calldata poolKey, IPoolManager.SwapParams calldata swapParams)
        internal
        view
        returns (int256 amount0, int256 amount1, uint160 sqrtPriceAfterX96, uint32 initializedTicksCrossed)
    {
        QuoteParams memory quoteParams = QuoteParams(
            swapParams.zeroForOne, swapParams.amountSpecified < 0, poolKey.fee, swapParams.sqrtPriceLimitX96
        );
        initializedTicksCrossed = 1;

        Slot0Struct memory slot0 = fillSlot0(poolManager, poolKey);

        SwapState memory state = SwapState({
            amountSpecifiedRemaining: -swapParams.amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: slot0.sqrtPriceX96,
            tick: slot0.tick,
            feeGrowthGlobalX128: 0,
            protocolFee: 0,
            liquidity: poolManager.getLiquidity(poolKey.toId())
        });

        while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != quoteParams.sqrtPriceLimitX96) {
            StepComputations memory step;

            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            (step.tickNext, step.initialized) = PoolTickBitmap.nextInitializedTickWithinOneWord(
                poolManager, poolKey.toId(), slot0.tickSpacing, state.tick, quoteParams.zeroForOne
            );

            // ensure that we do not overshoot the min/max tick, as the tick bitmap is not aware of these bounds
            if (step.tickNext < TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            } else if (step.tickNext > TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }

            // get the price for the next tick
            step.sqrtPriceNextX96 = TickMath.getSqrtPriceAtTick(step.tickNext);

            // compute values to swap to the target tick, price limit, or point where input/output amount is exhausted
            (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
                state.sqrtPriceX96,
                (
                    quoteParams.zeroForOne
                        ? step.sqrtPriceNextX96 < quoteParams.sqrtPriceLimitX96
                        : step.sqrtPriceNextX96 > quoteParams.sqrtPriceLimitX96
                ) ? quoteParams.sqrtPriceLimitX96 : step.sqrtPriceNextX96,
                state.liquidity,
                -state.amountSpecifiedRemaining,
                quoteParams.fee
            );

            if (quoteParams.exactInput) {
                state.amountSpecifiedRemaining -= (step.amountIn + step.feeAmount).toInt256();
                state.amountCalculated = state.amountCalculated + step.amountOut.toInt256();
            } else {
                state.amountSpecifiedRemaining += step.amountOut.toInt256();
                state.amountCalculated = state.amountCalculated - (step.amountIn + step.feeAmount).toInt256();
            }

            // shift tick if we reached the next price
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // if the tick is initialized, run the tick transition
                if (step.initialized) {
                    (, int128 liquidityNet,,) = poolManager.getTickInfo(poolKey.toId(), step.tickNext);

                    // if we're moving leftward, we interpret liquidityNet as the opposite sign
                    // safe because liquidityNet cannot be type(int128).min
                    if (quoteParams.zeroForOne) liquidityNet = -liquidityNet;

                    state.liquidity = LiquidityMath.addDelta(state.liquidity, liquidityNet);

                    initializedTicksCrossed++;
                }

                state.tick = quoteParams.zeroForOne ? step.tickNext - 1 : step.tickNext;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                // recompute unless we're on a lower tick boundary (i.e. already transitioned ticks), and haven't moved
                state.tick = TickMath.getTickAtSqrtPrice(state.sqrtPriceX96);
            }

            (amount0, amount1) = quoteParams.zeroForOne == quoteParams.exactInput
                ? (state.amountSpecifiedRemaining + swapParams.amountSpecified, state.amountCalculated)
                : (state.amountCalculated, state.amountSpecifiedRemaining + swapParams.amountSpecified);

            sqrtPriceAfterX96 = state.sqrtPriceX96;
        }
    }
}
