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

contract MiddlewareRemove is BaseMiddleware {
    using CustomRevert for bytes4;
    using Hooks for IHooks;

    error HookPermissionForbidden(address hooks);
    error HookModifiedDeltas();

    struct afterRemoveLiquidityParams {
        address sender;
        PoolKey key;
        IPoolManager.ModifyLiquidityParams params;
    }

    bytes internal constant ZERO_BYTES = bytes("");
    uint256 public constant gasLimit = 10000000;

    constructor(IPoolManager _manager, address _impl) BaseMiddleware(_manager, _impl) {
        if (IHooks(address(this)).hasPermission(Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG)) {
            HookPermissionForbidden.selector.revertWith(address(this));
        }
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external returns (bytes4) {
        implementation.delegatecall{gas: gasLimit}(msg.data);
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4, BalanceDelta) {
        address(this).delegatecall(abi.encodeWithSelector(this._callAndEnsureZeroDeltas.selector, msg.data));
        return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _callAndEnsureZeroDeltas(bytes calldata data) external {
        bytes32 slot = bytes32(NonZeroDeltaCount.NONZERO_DELTA_COUNT_SLOT);
        uint256 countBefore = uint256(IExttload(address(manager)).exttload(slot));
        address(implementation).delegatecall(msg.data);
        uint256 countAfter = uint256(IExttload(address(manager)).exttload(slot));
        if (countAfter > countBefore) {
            // purpousely revert to cause the whole hook to reset
            revert HookModifiedDeltas();
        }
    }
}
