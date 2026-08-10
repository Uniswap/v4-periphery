// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @notice Stands in for a custom permissioned-hook extension that requires `hookData` on removal.
/// @dev Mined with `BEFORE_REMOVE_LIQUIDITY_FLAG` only, so it is never invoked on add and cannot interfere
///      with seeding liquidity. Reverts on empty `hookData` so callers can assert the value was forwarded.
contract MockRemoveLiquidityDataHook {
    error HookDataRequired();

    bytes public lastHookData;

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata hookData)
        external
        returns (bytes4)
    {
        if (hookData.length == 0) revert HookDataRequired();
        lastHookData = hookData;
        return IHooks.beforeRemoveLiquidity.selector;
    }

    receive() external payable {}
}
