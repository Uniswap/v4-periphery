// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {BaseMiddleware} from "./BaseMiddleware.sol";
import {BaseHook} from "../../src/base/hooks/BaseHook.sol";
import {BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";

abstract contract BaseRemove is BaseMiddleware {
    using TransientStateLibrary for IPoolManager;

    /// @notice Thrown when hook permissions are forbidden
    /// @param hooks The address of this contract
    error HookPermissionForbidden(address hooks);

    /// @notice Thrown when there are nonzero deltas before the hook is called
    /// @dev Settle previous deltas before removing liquidity
    error MustResolveDeltasBeforeRemove();

    /// @notice Thrown when the implementation modified deltas
    error ImplementationModifiedDeltas();

    /// @notice Thrown when the implementation call failed
    error FailedImplementationCall();

    bytes internal constant ZERO_BYTES = bytes("");
    uint256 public constant GAS_LIMIT = 5_000_000;
    uint256 public constant MAX_BIPS = 10_000;

    /// @notice Value is keccak256("override") - 1
    /// @dev Use this hookData to override checks and save gas
    bytes32 constant OVERRIDE_BYTES = 0x23b70c8dec38c3dec67a5596870027b04c4058cb3ac57b4e589bf628ac6669e7;

    uint256 public immutable maxFeeBips;

    /// @param _manager The address of the pool manager
    /// @param _impl The address of the implementation contract
    constructor(IPoolManager _manager, address _impl) BaseMiddleware(_manager, _impl) {
        _ensureValidFlags();
    }

    /// @notice The hook called before liquidity is removed. Ensures zero nonzeroDeltas
    /// @param sender The initial msg.sender for the remove liquidity call
    /// @param key The key for the pool
    /// @param params The parameters for removing liquidity
    /// @param hookData Arbitrary data handed into the PoolManager by the liquidty provider to be be passed on to the hook
    ///                 Can call with OVERRIDE_BYTES to override checks
    /// @return bytes4 The function selector for the hook
    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4) {
        if (bytes32(hookData) == OVERRIDE_BYTES) {
            (, bytes memory returnData) = address(implementation).delegatecall(
                abi.encodeWithSelector(this.beforeRemoveLiquidity.selector, sender, key, params, hookData[32:])
            );
            return abi.decode(returnData, (bytes4));
        }
        if (manager.getNonzeroDeltaCount() != 0) {
            revert MustResolveDeltasBeforeRemove();
        }
        address(this).delegatecall{gas: GAS_LIMIT}(
            abi.encodeWithSelector(this._beforeRemoveLiquidity.selector, msg.data)
        );
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    /// @notice Middleware function that reverts if the implementation modified deltas
    /// @param data The calldata from beforeRemoveLiquidity
    function _beforeRemoveLiquidity(bytes calldata data) external {
        (bool success, bytes memory returnData) = address(implementation).delegatecall(data);
        if (!success) {
            revert FailedImplementationCall();
        }
        (bytes4 selector) = abi.decode(returnData, (bytes4));
        if (selector != BaseHook.beforeRemoveLiquidity.selector) {
            revert Hooks.InvalidHookResponse();
        }
        if (manager.getNonzeroDeltaCount() != 0) {
            revert ImplementationModifiedDeltas();
        }
    }

    /// @notice The hook called after liquidity is removed
    /// @param sender The initial msg.sender for the remove liquidity call
    /// @param key The key for the pool
    /// @param params The parameters for removing liquidity
    /// @param delta The caller's balance delta after removing liquidity
    /// @param hookData Arbitrary data handed into the PoolManager by the liquidty provider to be be passed on to the hook
    ///                 Can call with OVERRIDE_BYTES to override checks
    /// @return bytes4 The function selector for the hook
    /// @return BalanceDelta The hook's delta in token0 and token1. Positive: the hook is owed/took currency, negative: the hook owes/sent currency
    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external virtual returns (bytes4, BalanceDelta) {}

    /// @notice Ensure that the implementation contract has the correct hook flags
    /// @dev Override to enforce hook flags
    function _ensureValidFlags() internal view virtual {}
}
