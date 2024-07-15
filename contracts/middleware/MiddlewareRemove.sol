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
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

contract MiddlewareRemove is BaseMiddleware {
    using CustomRevert for bytes4;
    using Hooks for IHooks;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    error HookPermissionForbidden(address hooks);
    error HookModifiedPrice();
    error HookModifiedDeltas();
    error FailedImplementationCall();

    bytes internal constant ZERO_BYTES = bytes("");
    uint256 public constant GAS_LIMIT = 10_000_000;

    constructor(IPoolManager _manager, address _impl) BaseMiddleware(_manager, _impl) {
        if (IHooks(address(this)).hasPermission(Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG)) {
            HookPermissionForbidden.selector.revertWith(address(this));
        }
    }

    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4) {
        address(this).delegatecall{gas: GAS_LIMIT}(abi.encodeWithSelector(this._callAndEnsurePrice.selector, msg.data));
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function _callAndEnsurePrice(bytes calldata data) external {
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
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4, BalanceDelta) {
        address(this).delegatecall{gas: GAS_LIMIT}(
            abi.encodeWithSelector(this._callAndEnsureZeroDeltas.selector, msg.data)
        );
        return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _callAndEnsureZeroDeltas(bytes calldata data) external {
        bytes32 slot = bytes32(NonZeroDeltaCount.NONZERO_DELTA_COUNT_SLOT);
        uint256 countBefore = uint256(IExttload(address(manager)).exttload(slot));
        (bool success,) = address(implementation).delegatecall(data);
        if (!success) {
            revert FailedImplementationCall();
        }
        uint256 countAfter = uint256(IExttload(address(manager)).exttload(slot));
        if (countAfter != countBefore) {
            // purpousely revert to cause the whole hook to reset
            revert HookModifiedDeltas();
        }
    }
}
