// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {BaseMiddleware} from "./BaseMiddleware.sol";
import {BaseHook} from "../BaseHook.sol";
import {BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {NonZeroDeltaCount} from "@uniswap/v4-core/src/libraries/NonZeroDeltaCount.sol";
import {IExttload} from "@uniswap/v4-core/src/interfaces/IExttload.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

contract MiddlewareRemoveNoDeltas is BaseMiddleware {
    using CustomRevert for bytes4;
    using Hooks for IHooks;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    error HookPermissionForbidden(address hooks);
    error HookModifiedPrice();
    error HookModifiedDeltas();
    error FailedImplementationCall();

    bytes internal constant ZERO_BYTES = bytes("");
    uint256 public constant GAS_LIMIT = 10_000_000;

    constructor(IPoolManager _manager, address _impl) BaseMiddleware(_manager, _impl) {}

    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4) {
        address(this).delegatecall{gas: GAS_LIMIT}(
            abi.encodeWithSelector(this._callAndEnsurePriceNoDeltas.selector, msg.data)
        );
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    // if this reverts, the entire hook will be undone
    function _callAndEnsurePriceNoDeltas(bytes calldata data) external {
        (, PoolKey memory key,,) = abi.decode(data[4:], (address, PoolKey, IPoolManager.ModifyLiquidityParams, bytes));
        (uint160 priceBefore,,,) = manager.getSlot0(key.toId());
        (bool success,) = address(implementation).delegatecall(data);
        if (!success) {
            revert FailedImplementationCall();
        }
        (uint160 priceAfter,,,) = manager.getSlot0(key.toId());
        if (priceAfter != priceBefore) {
            // purpousely revert to cause the whole hook to reset
            revert HookModifiedPrice();
        }
        _ensureNoDeltas();
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4, BalanceDelta) {
        address(this).delegatecall{gas: GAS_LIMIT}(
            abi.encodeWithSelector(this._callAndEnsureNoDeltas.selector, msg.data)
        );
        return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    // if this reverts, the entire hook will be undone
    function _callAndEnsureNoDeltas(bytes calldata data) external {
        (bool success,) = address(implementation).delegatecall(data);
        if (!success) {
            revert FailedImplementationCall();
        }
        _ensureNoDeltas();
    }

    function _ensureNoDeltas() internal view {
        if (manager.getNonzeroDeltaCount() != 0) {
            revert HookModifiedDeltas();
        }
    }

    function _ensureValidFlags(address _impl) internal view virtual override {
        if (uint160(address(this)) & Hooks.ALL_HOOK_MASK != uint160(_impl) & Hooks.ALL_HOOK_MASK) {
            revert FlagsMismatch();
        }
        if (IHooks(address(this)).hasPermission(Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG)) {
            HookPermissionForbidden.selector.revertWith(address(this));
        }
    }
}
