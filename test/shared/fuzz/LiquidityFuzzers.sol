// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Fuzzers} from "@uniswap/v4-core/src/test/Fuzzers.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IPositionManager} from "../../../src/interfaces/IPositionManager.sol";
import {Actions} from "../../../src/libraries/Actions.sol";
import {Planner, Plan} from "../../shared/Planner.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

contract LiquidityFuzzers is Fuzzers {
    uint128 constant _MAX_SLIPPAGE_INCREASE = type(uint128).max;

    function addFuzzyLiquidity(
        IPositionManager lpm,
        address recipient,
        PoolKey memory key,
        ModifyLiquidityParams memory params,
        uint160 sqrtPriceX96,
        bytes memory hookData
    ) internal returns (uint256, ModifyLiquidityParams memory) {
        params = Fuzzers.createFuzzyLiquidityParams(key, params, sqrtPriceX96);

        Plan memory planner = Planner.init()
            .add(
                Actions.MINT_POSITION,
                abi.encode(
                    key,
                    params.tickLower,
                    params.tickUpper,
                    uint256(params.liquidityDelta),
                    _MAX_SLIPPAGE_INCREASE,
                    _MAX_SLIPPAGE_INCREASE,
                    recipient,
                    hookData
                )
            );

        uint256 tokenId = lpm.nextTokenId();
        bytes memory calls = planner.finalizeModifyLiquidityWithClose(key);
        lpm.modifyLiquidities(calls, block.timestamp + 1);

        return (tokenId, params);
    }

    /// @dev Like `createFuzzyLiquidityParams`, but forces a two-sided (straddle-0) range STRUCTURALLY via
    ///      `bound`: `tickLower` strictly negative, `tickUpper` strictly positive, each at least
    ///      `minSpacingsPerSide` tick-spacings from 0, so tests need no `vm.assume(tickLower < 0 && 0 < tickUpper)`
    ///      that discards a large fraction of inputs (and trips `max_test_rejects` once fuzz runs are honored).
    ///      Liquidity is sized from the forced ticks exactly as the base helper does, so the range and its
    ///      `liquidityDelta` stay consistent.
    function createFuzzyTwoSidedLiquidityParams(
        PoolKey memory key,
        ModifyLiquidityParams memory params,
        uint160 sqrtPriceX96,
        uint256 minSpacingsPerSide
    ) internal pure returns (ModifyLiquidityParams memory result) {
        int24 spacing = key.tickSpacing;
        int24 minInner = int24(int256(minSpacingsPerSide)) * spacing;

        // Bound each side into its own half of the usable range; integer division truncates toward zero, so
        // aligning never crosses 0 and each side keeps at least `minInner` of distance from it.
        int24 tickLower =
            int24(bound(int256(params.tickLower), int256(TickMath.minUsableTick(spacing)), int256(-minInner)));
        int24 tickUpper =
            int24(bound(int256(params.tickUpper), int256(minInner), int256(TickMath.maxUsableTick(spacing))));
        result.tickLower = (tickLower / spacing) * spacing;
        result.tickUpper = (tickUpper / spacing) * spacing;

        result.liquidityDelta = boundLiquidityDelta(
            key, params.liquidityDelta, getLiquidityDeltaFromAmounts(result.tickLower, result.tickUpper, sqrtPriceX96)
        );
    }

    /// @dev Two-sided fuzzed params with at least one tick-spacing per side (the common `tickLower < 0 < tickUpper`).
    function createFuzzyTwoSidedLiquidityParams(
        PoolKey memory key,
        ModifyLiquidityParams memory params,
        uint160 sqrtPriceX96
    ) internal pure returns (ModifyLiquidityParams memory) {
        return createFuzzyTwoSidedLiquidityParams(key, params, sqrtPriceX96, 1);
    }

    /// @dev `addFuzzyLiquidity` over a forced two-sided range (see `createFuzzyTwoSidedLiquidityParams`).
    function addFuzzyTwoSidedLiquidity(
        IPositionManager lpm,
        address recipient,
        PoolKey memory key,
        ModifyLiquidityParams memory params,
        uint160 sqrtPriceX96,
        bytes memory hookData
    ) internal returns (uint256, ModifyLiquidityParams memory) {
        params = createFuzzyTwoSidedLiquidityParams(key, params, sqrtPriceX96);

        Plan memory planner = Planner.init()
            .add(
                Actions.MINT_POSITION,
                abi.encode(
                    key,
                    params.tickLower,
                    params.tickUpper,
                    uint256(params.liquidityDelta),
                    _MAX_SLIPPAGE_INCREASE,
                    _MAX_SLIPPAGE_INCREASE,
                    recipient,
                    hookData
                )
            );

        uint256 tokenId = lpm.nextTokenId();
        bytes memory calls = planner.finalizeModifyLiquidityWithClose(key);
        lpm.modifyLiquidities(calls, block.timestamp + 1);

        return (tokenId, params);
    }
}
