// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {IBaseLiquidityManagement} from "./IBaseLiquidityManagement.sol";
import {LiquidityPosition} from "../types/LiquidityPositionId.sol";

interface IAdvancedLiquidityManagement is IBaseLiquidityManagement {
    /// @notice Move an existing liquidity position into a new range
    function rebalanceLiquidity(
        LiquidityPosition memory position,
        int24 tickLowerNew,
        int24 tickUpperNew,
        int256 liquidityDelta
    ) external;

    /// @notice Move an existing liquidity position into a new pool, keeping the same range
    function migrateLiquidity(LiquidityPosition memory position, PoolKey memory newKey) external;
}
