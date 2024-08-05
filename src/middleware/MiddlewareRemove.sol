// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {BaseRemove} from "./BaseRemove.sol";
import {BaseHook} from "../../src/base/hooks/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookFees} from "../../src/libraries/HookFees.sol";

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

    uint256 public immutable maxFeeBips;

    /// @param _poolManager The address of the pool manager
    /// @param _impl The address of the implementation contract
    /// @param _maxFeeBips The maximum fee in basis points the hook is allowed to charge on removeLiquidity
    constructor(IPoolManager _poolManager, address _impl, uint256 _maxFeeBips) BaseRemove(_poolManager, _impl) {
        if (_maxFeeBips > HookFees.MAX_BIPS) revert MaxFeeBipsTooHigh();
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
        uint256 unaccountedNonzeroDeltas = poolManager.getNonzeroDeltaCount();
        if (unaccountedNonzeroDeltas == 0 && returnDelta == BalanceDeltaLibrary.ZERO_DELTA) {
            return returnDelta;
        }
        (int256 fee0, int256 fee1) = HookFees.calculateFeesFrom(delta, maxFeeBips);
        if (returnDelta.amount0() > fee0 || returnDelta.amount1() > fee1) {
            revert TookTooMuchFee();
        }
        returnDelta - delta; // revert on overflow

        unaccountedNonzeroDeltas =
            validateAndCountDeltas(key.currency0, returnDelta.amount0(), unaccountedNonzeroDeltas);
        unaccountedNonzeroDeltas =
            validateAndCountDeltas(key.currency1, returnDelta.amount1(), unaccountedNonzeroDeltas);

        if (unaccountedNonzeroDeltas == 0) {
            return returnDelta;
        }

        // if the hook settled the caller's deltas
        if (poolManager.currencyDelta(sender, key.currency0) != 0) {
            unchecked {
                unaccountedNonzeroDeltas--;
            }
        }
        if (poolManager.currencyDelta(sender, key.currency1) != 0) {
            unchecked {
                unaccountedNonzeroDeltas--;
            }
        }
        if (unaccountedNonzeroDeltas == 0) {
            return returnDelta;
        }
        revert InvalidDeltasOwner();
    }

    function validateAndCountDeltas(Currency currency, int128 returnAmount, uint256 unaccountedNonzeroDeltas)
        internal
        view
        returns (uint256)
    {
        int256 hookDelta = poolManager.currencyDelta(address(this), currency);
        unchecked {
            // unchecked negation is safe because even if hookDelta is int256.min, returnAmount can not be int256.min
            if (-hookDelta != returnAmount) {
                revert DeltasReturnMismatch();
            }
            if (hookDelta != 0) {
                unaccountedNonzeroDeltas--;
            }
        }
        return unaccountedNonzeroDeltas;
    }

    function _ensureValidFlags() internal view virtual override {
        if (!IHooks(address(this)).hasPermission(Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG)) {
            HookPermissionForbidden.selector.revertWith(address(this));
        }
    }
}
