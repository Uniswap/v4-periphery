// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {BaseRemove} from "./BaseRemove.sol";
import {BaseHook} from "../../src/base/hooks/BaseHook.sol";
import {BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";

contract MiddlewareRemoveNoDeltas is BaseRemove {
    using CustomRevert for bytes4;
    using Hooks for IHooks;
    using TransientStateLibrary for IPoolManager;

    /// @param _manager The address of the pool manager
    /// @param _impl The address of the implementation contract
    constructor(IPoolManager _manager, address _impl) BaseRemove(_manager, _impl) {}

    /// @notice The hook called after liquidity is removed. Ensures zero nonzeroDeltas
    /// @inheritdoc BaseRemove
    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override returns (bytes4, BalanceDelta) {
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

    /// @notice Middleware function that reverts if the implementation modified deltas
    /// @param data The calldata from afterRemoveLiquidity
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
            revert ImplementationModifiedDeltas();
        }
    }

    function _ensureValidFlags() internal view virtual override {
        if (IHooks(address(this)).hasPermission(Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG)) {
            HookPermissionForbidden.selector.revertWith(address(this));
        }
    }
}
