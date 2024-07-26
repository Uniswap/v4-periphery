// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {BaseRemove} from "./BaseRemove.sol";
import {BaseHook} from "../BaseHook.sol";
import {BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";

contract MiddlewareRemoveNoDeltas is BaseRemove {
    using CustomRevert for bytes4;
    using Hooks for IHooks;
    using TransientStateLibrary for IPoolManager;

    constructor(IPoolManager _manager, address _impl) BaseRemove(_manager, _impl) {}

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4, BalanceDelta) {
        if (bytes32(hookData) == OVERRIDE_BYTES) {
            (, bytes memory returnData) = address(implementation).delegatecall(
                abi.encodeWithSelector(this.afterRemoveLiquidity.selector, sender, key, params, delta, hookData[32:])
            );
            return abi.decode(returnData, (bytes4, BalanceDelta));
        }
        address(this).delegatecall{gas: GAS_LIMIT}(
            abi.encodeWithSelector(this._afterRemoveLiquidity.selector, msg.data)
        );
        return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _afterRemoveLiquidity(bytes calldata data) external {
        (bool success, bytes memory returnData) = address(implementation).delegatecall(data);
        if (!success) {
            revert FailedImplementationCall();
        }
        (bytes4 selector, BalanceDelta returnDelta) = abi.decode(returnData, (bytes4, BalanceDelta));
        if (selector != BaseHook.afterRemoveLiquidity.selector) {
            revert Hooks.InvalidHookResponse();
        }
        if (manager.getNonzeroDeltaCount() != 0 || returnDelta != BalanceDeltaLibrary.ZERO_DELTA) {
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
