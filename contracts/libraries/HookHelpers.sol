// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

library HookHelpers {
    /// @notice Function to calculate flags from permissions
    /// @param permissions The permissions to convert to flags
    /// @return out The flags that correspond to the permissions
    function flags(Hooks.Permissions memory permissions) internal pure returns (uint160 out) {
        if (permissions.beforeInitialize) out |= Hooks.BEFORE_INITIALIZE_FLAG;
        if (permissions.afterInitialize) out |= Hooks.AFTER_INITIALIZE_FLAG;
        if (permissions.beforeAddLiquidity) out |= Hooks.BEFORE_ADD_LIQUIDITY_FLAG;
        if (permissions.afterAddLiquidity) out |= Hooks.AFTER_ADD_LIQUIDITY_FLAG;
        if (permissions.beforeRemoveLiquidity) out |= Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
        if (permissions.afterRemoveLiquidity) out |= Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;
        if (permissions.beforeSwap) out |= Hooks.BEFORE_SWAP_FLAG;
        if (permissions.afterSwap) out |= Hooks.AFTER_SWAP_FLAG;
        if (permissions.beforeDonate) out |= Hooks.BEFORE_DONATE_FLAG;
        if (permissions.afterDonate) out |= Hooks.AFTER_DONATE_FLAG;
        if (permissions.beforeSwapReturnDelta) out |= Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
        if (permissions.afterSwapReturnDelta) out |= Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        if (permissions.afterAddLiquidityReturnDelta) out |= Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG;
        if (permissions.afterRemoveLiquidityReturnDelta) out |= Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;
    }
}
