// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {BaseMiddleware} from "./BaseMiddleware.sol";
import {BaseHook} from "../BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {NonZeroDeltaCount} from "@uniswap/v4-core/src/libraries/NonZeroDeltaCount.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

contract MiddlewareRemove is BaseMiddleware {
    using CustomRevert for bytes4;
    using Hooks for IHooks;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    error HookPermissionForbidden(address hooks);
    error HookModifiedDeltasBeforeRemove();
    error HookTookTooMuchFee();
    error HookInvalidDeltasAfterRemove();
    error FailedImplementationCall();
    error MaxFeeBipsTooHigh();

    bytes internal constant ZERO_BYTES = bytes("");
    uint256 public constant GAS_LIMIT = 10_000_000;
    uint256 public constant MAX_BIPS = 10_000;

    uint256 public immutable maxFeeBips;

    constructor(IPoolManager _manager, address _impl, uint256 _maxFeeBips) BaseMiddleware(_manager, _impl) {
        if (_maxFeeBips > MAX_BIPS) revert MaxFeeBipsTooHigh();
        maxFeeBips = _maxFeeBips;
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external returns (bytes4) {
        address(this).delegatecall{gas: GAS_LIMIT}(
            abi.encodeWithSelector(this._callAndEnsureNoDeltas.selector, msg.data)
        );
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function _callAndEnsureNoDeltas(bytes calldata data) external {
        (bool success, bytes memory returnData) = address(implementation).delegatecall(data);
        if (!success) {
            revert FailedImplementationCall();
        }
        (bytes4 selector) = abi.decode(returnData, (bytes4));
        if (selector != BaseHook.beforeRemoveLiquidity.selector) {
            revert Hooks.InvalidHookResponse();
        }
        if (manager.getNonzeroDeltaCount() != 0) {
            revert HookModifiedDeltasBeforeRemove();
        }
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4, BalanceDelta) {
        (bool success, bytes memory returnData) = address(this).delegatecall{gas: GAS_LIMIT}(
            abi.encodeWithSelector(this._callAndEnsureValidDeltas.selector, sender, key, params, delta, hookData)
        );
        if (success) {
            return (BaseHook.afterRemoveLiquidity.selector, abi.decode(returnData, (BalanceDelta)));
        } else {
            return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
        }
    }

    function _callAndEnsureValidDeltas(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (BalanceDelta) {
        (bool success, bytes memory returnData) = address(implementation).delegatecall(
            abi.encodeWithSelector(this.afterRemoveLiquidity.selector, sender, key, params, delta, hookData)
        );
        if (!success) {
            revert FailedImplementationCall();
        }
        (bytes4 selector, BalanceDelta returnDelta) = abi.decode(returnData, (bytes4, BalanceDelta));
        if (selector != BaseHook.afterRemoveLiquidity.selector) {
            revert Hooks.InvalidHookResponse();
        }
        uint256 nonzeroDeltaCount = manager.getNonzeroDeltaCount();
        if (nonzeroDeltaCount == 0 && returnDelta == BalanceDeltaLibrary.ZERO_DELTA) {
            return returnDelta;
        }
        if (
            returnDelta.amount0() > int256(uint256(int256(delta.amount0())) * maxFeeBips / MAX_BIPS)
                || returnDelta.amount1() > int256(uint256(int256(delta.amount1())) * maxFeeBips / MAX_BIPS)
        ) {
            revert HookTookTooMuchFee();
        }
        uint256 nonzeroHookDeltaCount;
        int256 hookDelta = manager.currencyDelta(address(this), key.currency0);
        if (hookDelta != 0) {
            if (-hookDelta != returnDelta.amount0()) {
                revert HookInvalidDeltasAfterRemove();
            }
            nonzeroHookDeltaCount++;
            if (nonzeroHookDeltaCount == nonzeroDeltaCount) {
                return returnDelta;
            }
        }
        hookDelta = manager.currencyDelta(address(this), key.currency1);
        if (hookDelta != 0) {
            if (-hookDelta != returnDelta.amount1()) {
                revert HookInvalidDeltasAfterRemove();
            }
            nonzeroHookDeltaCount++;
            if (nonzeroHookDeltaCount == nonzeroDeltaCount) {
                return returnDelta;
            }
        }

        // weird edge case in case the hook settled the caller's deltas
        if (manager.currencyDelta(sender, key.currency0) != 0) {
            nonzeroHookDeltaCount++;
        }
        if (manager.currencyDelta(sender, key.currency1) != 0) {
            nonzeroHookDeltaCount++;
        }
        if (nonzeroHookDeltaCount == nonzeroDeltaCount) {
            return returnDelta;
        }

        revert HookInvalidDeltasAfterRemove();
    }

    function _ensureValidFlags(address _impl) internal view virtual override {
        if (uint160(address(this)) & Hooks.ALL_HOOK_MASK != uint160(_impl) & Hooks.ALL_HOOK_MASK) {
            revert FlagsMismatch();
        }
        if (!IHooks(address(this)).hasPermission(Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG)) {
            HookPermissionForbidden.selector.revertWith(address(this));
        }
    }
}
