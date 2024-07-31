// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {BaseRemove} from "./BaseRemove.sol";
import {BaseHook} from "../BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {NonZeroDeltaCount} from "@uniswap/v4-core/src/libraries/NonZeroDeltaCount.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";

contract MiddlewareRemove is BaseRemove {
    using CustomRevert for bytes4;
    using Hooks for IHooks;
    using TransientStateLibrary for IPoolManager;

    /// @notice Thrown when the implementation takes more fees than the max fee
    error TookTooMuchFee();

    /// @notice Thrown when the implementation returns different deltas than it modified
    error DeltasReturnMismatch();

    /// @notice Thrown when the implementation modifies deltas not of the hook or caller
    error InvalidDeltasOwner();

    /// @notice Thrown when maxFeeBips is set to a value greater than 10,000
    error MaxFeeBipsTooHigh();

    /// @param _manager The address of the pool manager
    /// @param _impl The address of the implementation contract
    constructor(IPoolManager _manager, address _impl, uint256 _maxFeeBips) BaseRemove(_manager, _impl) {
        if (_maxFeeBips > MAX_BIPS) revert MaxFeeBipsTooHigh();
        maxFeeBips = _maxFeeBips;
    }

    /// @notice The hook called after liquidity is removed. Ensures valid deltas
    /// @inheritdoc BaseRemove
    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override returns (bytes4, BalanceDelta) {
        if (bytes32(hookData) == OVERRIDE_BYTES) {
            (, bytes memory implReturnData) = address(implementation).delegatecall(
                abi.encodeWithSelector(this.afterRemoveLiquidity.selector, sender, key, params, delta, hookData[32:])
            );
            return abi.decode(implReturnData, (bytes4, BalanceDelta));
        }
        (bool success, bytes memory returnData) = address(this).delegatecall{gas: GAS_LIMIT}(
            abi.encodeWithSelector(this._afterRemoveLiquidity.selector, sender, key, params, delta, hookData)
        );
        if (success) {
            return (BaseHook.afterRemoveLiquidity.selector, abi.decode(returnData, (BalanceDelta)));
        } else {
            return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
        }
    }

    /// @notice Middleware function that reverts if the implementation modified deltas incorrectly
    /// @param sender The same sender from afterRemoveLiquidity
    /// @param key The same key from afterRemoveLiquidity
    /// @param params The same params from afterRemoveLiquidity
    /// @param delta The same delta from afterRemoveLiquidity
    /// @param hookData The same hookData from afterRemoveLiquidity
    function _afterRemoveLiquidity(
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
            revert TookTooMuchFee();
        }
        returnDelta - delta; // revert on overflow
        uint256 nonzeroHookDeltaCount;
        int256 hookDelta = manager.currencyDelta(address(this), key.currency0);
        if (hookDelta != 0) {
            if (-hookDelta != returnDelta.amount0()) {
                revert DeltasReturnMismatch();
            }
            nonzeroHookDeltaCount++;
            if (nonzeroHookDeltaCount == nonzeroDeltaCount) {
                return returnDelta;
            }
        }
        hookDelta = manager.currencyDelta(address(this), key.currency1);
        if (hookDelta != 0) {
            if (-hookDelta != returnDelta.amount1()) {
                revert DeltasReturnMismatch();
            }
            nonzeroHookDeltaCount++;
            if (nonzeroHookDeltaCount == nonzeroDeltaCount) {
                return returnDelta;
            }
        }

        // if the hook settled the caller's deltas
        if (manager.currencyDelta(sender, key.currency0) != 0) {
            nonzeroHookDeltaCount++;
        }
        if (manager.currencyDelta(sender, key.currency1) != 0) {
            nonzeroHookDeltaCount++;
        }
        if (nonzeroHookDeltaCount == nonzeroDeltaCount) {
            return returnDelta;
        }

        revert InvalidDeltasOwner();
    }

    function _ensureValidFlags() internal view virtual override {
        if (!IHooks(address(this)).hasPermission(Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG)) {
            HookPermissionForbidden.selector.revertWith(address(this));
        }
    }
}
