// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IBaseHook} from "./../interfaces/IBaseHook.sol";
import {BaseHook} from "./../BaseHook.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

contract BaseMiddleware is IHooks {
    error NotManager();

    IPoolManager public immutable manager;
    IBaseHook public immutable implementation;

    constructor(IPoolManager _manager, IBaseHook _implementation) {
        manager = _manager;
        implementation = _implementation;
    }

    modifier onlyByManager() {
        if (msg.sender != address(manager)) revert NotManager();
        _;
    }

    function getHookPermissions() public view returns (Hooks.Permissions memory) {
        return implementation.getHookPermissions();
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, bytes calldata hookData)
        external
        virtual
        onlyByManager
        returns (bytes4)
    {
        if (msg.sender == address(implementation)) return BaseHook.beforeInitialize.selector;
        return implementation.beforeInitialize(sender, key, sqrtPriceX96, hookData);
    }

    function afterInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick,
        bytes calldata hookData
    ) external virtual onlyByManager returns (bytes4) {
        if (msg.sender == address(implementation)) return BaseHook.afterInitialize.selector;
        return implementation.afterInitialize(sender, key, sqrtPriceX96, tick, hookData);
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external virtual onlyByManager returns (bytes4) {
        if (msg.sender == address(implementation)) return BaseHook.beforeAddLiquidity.selector;
        return implementation.beforeAddLiquidity(sender, key, params, hookData);
    }

    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external virtual onlyByManager returns (bytes4, BalanceDelta) {
        if (msg.sender == address(implementation)) {
            return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
        }
        return implementation.afterAddLiquidity(sender, key, params, delta, hookData);
    }

    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external virtual onlyByManager returns (bytes4) {
        if (msg.sender == address(implementation)) return BaseHook.beforeRemoveLiquidity.selector;
        return implementation.beforeRemoveLiquidity(sender, key, params, hookData);
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external virtual onlyByManager returns (bytes4, BalanceDelta) {
        if (msg.sender == address(implementation)) {
            return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
        }
        return implementation.afterRemoveLiquidity(sender, key, params, delta, hookData);
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external virtual onlyByManager returns (bytes4, BeforeSwapDelta, uint24) {
        if (msg.sender == address(implementation)) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        return implementation.beforeSwap(sender, key, params, hookData);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external virtual onlyByManager returns (bytes4, int128) {
        if (msg.sender == address(implementation)) {
            return (BaseHook.afterSwap.selector, 0);
        }
        return implementation.afterSwap(sender, key, params, delta, hookData);
    }

    function beforeDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    ) external virtual onlyByManager returns (bytes4) {
        if (msg.sender == address(implementation)) return BaseHook.beforeDonate.selector;
        return implementation.beforeDonate(sender, key, amount0, amount1, hookData);
    }

    function afterDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    ) external virtual onlyByManager returns (bytes4) {
        if (msg.sender == address(implementation)) return BaseHook.afterDonate.selector;
        return implementation.afterDonate(sender, key, amount0, amount1, hookData);
    }
}
