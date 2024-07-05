// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BaseMiddleware} from "./BaseMiddleware.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {console} from "../../lib/forge-std/src/console.sol";
import {BaseHook} from "./../BaseHook.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

contract MiddlewareProtect is BaseMiddleware {
    using StateLibrary for IPoolManager;
    using Hooks for IHooks;

    /// @notice Thrown if the address will lead to forbidden flags being set
    /// @param hooks The address of the hooks contract
    error HookPermissionForbidden(address hooks);
    error ForbiddenReturn();

    uint256 public constant gasLimit = 1000000;

    constructor(IPoolManager _poolManager, IHooks _implementation) BaseMiddleware(_poolManager, _implementation) {
        // deny any hooks that return deltas
        if (
            _implementation.hasPermission(Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG)
                || _implementation.hasPermission(Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG)
                || _implementation.hasPermission(Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG)
                || _implementation.hasPermission(Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG)
        ) {
            HookPermissionForbidden.selector.revertWith(address(this));
        }
    }

    // block swaps and removes
    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        swapNotLocked
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        ReentrancyState.lockSwapRemove();
        console.log("beforeSwap middleware");
        (bytes4 selector, BeforeSwapDelta beforeSwapDelta, uint24 lpFeeOverride) =
            implementation.beforeSwap(sender, key, params, hookData);
        if (lpFeeOverride != 0) {
            revert ForbiddenReturn();
        }
        return (selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // afterSwap - no protections

    // block swaps
    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        returns (bytes4)
    {
        ReentrancyState.lockSwap();
        console.log("beforeAddLiquidity middleware");
        selector = implementation.beforeSwap(sender, key, params, hookData);
        ReentrancyState.unlock();
        return selector;
    }

    // afterAddLiquidity - no protections

    // block swaps and reverts
    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external removeNotLocked returns (bytes4) {
        ReentrancyState.lockSwap();
        console.log("beforeRemoveLiquidity middleware");
        implementation.call{gas: gasLimit}(msg.data);
        ReentrancyState.unlock();
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    // block reverts
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        bytes calldata
    ) external returns (bytes4, BalanceDelta) {
        console.log("afterRemoveLiquidity middleware");
        implementation.delegatecall{gas: gasLimit}(msg.data);
        return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }
}
