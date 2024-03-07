// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {INonfungiblePositionManager} from "../../../contracts/interfaces/INonfungiblePositionManager.sol";
import {LiquidityPosition} from "../../../contracts/types/LiquidityPositionId.sol";

contract LiquidityFuzzers is StdUtils {
    Vm internal constant _vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    /// @dev Obtain fuzzed parameters for creating liquidity
    /// @param key The pool key
    /// @param tickLower The lower tick
    /// @param tickUpper The upper tick
    /// @param liquidityDelta The liquidity delta

    function createFuzzyLiquidityParams(PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidityDelta)
        internal
        view
        returns (int24 _tickLower, int24 _tickUpper, uint128 _liquidityDelta)
    {
        _vm.assume(0.0000001e18 < liquidityDelta);

        _vm.assume(liquidityDelta < Pool.tickSpacingToMaxLiquidityPerTick(key.tickSpacing));

        tickLower = int24(
            bound(
                int256(tickLower),
                int256(TickMath.minUsableTick(key.tickSpacing)),
                int256(TickMath.maxUsableTick(key.tickSpacing))
            )
        );
        tickUpper = int24(
            bound(
                int256(tickUpper),
                int256(TickMath.minUsableTick(key.tickSpacing)),
                int256(TickMath.maxUsableTick(key.tickSpacing))
            )
        );

        // round down ticks
        tickLower = (tickLower / key.tickSpacing) * key.tickSpacing;
        tickUpper = (tickUpper / key.tickSpacing) * key.tickSpacing;
        _vm.assume(tickLower < tickUpper);

        _tickLower = tickLower;
        _tickUpper = tickUpper;
        _liquidityDelta = liquidityDelta;
    }

    function createFuzzyLiquidity(
        INonfungiblePositionManager lpm,
        address recipient,
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityDelta,
        bytes memory hookData
    )
        internal
        returns (uint256 _tokenId, int24 _tickLower, int24 _tickUpper, uint128 _liquidityDelta, BalanceDelta _delta)
    {
        (_tickLower, _tickUpper, _liquidityDelta) =
            createFuzzyLiquidityParams(key, tickLower, tickUpper, liquidityDelta);
        (_tokenId, _delta) = lpm.mint(
            LiquidityPosition({key: key, tickLower: _tickLower, tickUpper: _tickUpper}),
            _liquidityDelta,
            block.timestamp,
            recipient,
            hookData
        );
    }

    function createFuzzyAmountDesired(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) internal view returns (uint256 _amount0, uint256 _amount1) {
        // fuzzing amount desired is a nice to have instead of using liquidityDelta, however we often violate TickOverflow
        // (too many tokens in a tight range) -- need to figure out how to bound it better
        bool tight = (tickUpper - tickLower) < 300 * key.tickSpacing;
        uint256 maxAmount0 = tight ? 100e18 : 1_000e18;
        uint256 maxAmount1 = tight ? 100e18 : 1_000e18;
        _amount0 = bound(amount0, 0, maxAmount0);
        _amount1 = bound(amount1, 0, maxAmount1);
        _vm.assume(_amount0 != 0 && _amount1 != 0);
    }
}
