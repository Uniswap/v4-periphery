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
import {IBaseHook} from "./../interfaces/IBaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ReentrancyState} from "./../libraries/ReentrancyState.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

contract MiddlewareProtect is BaseMiddleware {
    using CustomRevert for bytes4;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    /// @notice Thrown if the address will lead to forbidden flags being set
    /// @param hooks The address of the hooks contract
    error HookPermissionForbidden(address hooks);
    error ForbiddenReturn();
    error InvalidFee();
    error ActionBetweenHook();

    uint256 public constant gasLimit = 1000000;

    constructor(IPoolManager _poolManager, IBaseHook _implementation) BaseMiddleware(_poolManager, _implementation) {
        Hooks.Permissions memory permissions = _implementation.getHookPermissions();
        // deny any hooks that return deltas
        if (
            permissions.beforeSwapReturnDelta || permissions.afterSwapReturnDelta
                || permissions.afterAddLiquidityReturnDelta || permissions.afterRemoveLiquidityReturnDelta
        ) {
            HookPermissionForbidden.selector.revertWith(address(this));
        }
    }

    modifier swapNotLocked() {
        if (ReentrancyState.swapLocked()) {
            revert ActionBetweenHook();
        }
        _;
    }

    modifier removeNotLocked() {
        if (ReentrancyState.removeLocked()) {
            revert ActionBetweenHook();
        }
        _;
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, bytes calldata hookData)
        external
        override
        onlyByManager
        returns (bytes4)
    {
        if (key.fee.isDynamicFee()) revert InvalidFee();
        if (msg.sender == address(implementation)) {
            return BaseHook.beforeInitialize.selector;
        }
        return implementation.beforeInitialize(sender, key, sqrtPriceX96, hookData);
    }

    // block swaps and removes
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external override swapNotLocked returns (bytes4, BeforeSwapDelta, uint24) {
        ReentrancyState.lockSwapRemove();
        console.log("beforeSwap middleware");
        if (msg.sender == address(implementation)) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = implementation.beforeSwap(sender, key, params, hookData);
        ReentrancyState.unlock();
        return (selector, delta, fee);
    }

    // afterSwap - no protections

    // block swaps
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4) {
        ReentrancyState.lockSwap();
        console.log("beforeAddLiquidity middleware");
        bytes4 selector = implementation.beforeAddLiquidity(sender, key, params, hookData);
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
    ) external override removeNotLocked returns (bytes4) {
        ReentrancyState.lockSwap();
        console.log("beforeRemoveLiquidity middleware");
        address(implementation).call{gas: gasLimit}(msg.data);
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
    ) external override returns (bytes4, BalanceDelta) {
        console.log("afterRemoveLiquidity middleware");
        address(implementation).call{gas: gasLimit}(msg.data);
        return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }
}
