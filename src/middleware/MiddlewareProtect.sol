// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {BaseHook} from "../base/hooks/BaseHook.sol";
import {BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BaseMiddleware} from "./BaseMiddleware.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {CheapQuoter} from "./CheapQuoter.sol";
import {Quote} from "../libraries/Quote.sol";

contract MiddlewareProtect is BaseMiddleware {
    using CustomRevert for bytes4;
    using Hooks for IHooks;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;
    using LPFeeLibrary for uint24;
    using BalanceDeltaLibrary for BalanceDelta;

    /// @notice Thrown when hook permissions are forbidden
    /// @param hooks The address of this contract
    error HookPermissionForbidden(address hooks);

    /// @notice Thrown when both flags match, but deployer must use AFTER_SWAP_FLAG
    /// @dev redeploy with AFTER_SWAP_FLAG
    error MustHaveAfterSwapFlagOnMiddleware();

    /// @notice Thrown when the implementation modified the output of a swap
    error HookModifiedOutput();

    bytes internal constant ZERO_BYTES = bytes("");

    CheapQuoter public immutable cheapQuoter;

    constructor(IPoolManager _poolManager, CheapQuoter _cheapQuoter, address _impl)
        BaseMiddleware(_poolManager, _impl)
    {
        cheapQuoter = _cheapQuoter;
        _ensureValidFlags();
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        Quote.set(cheapQuoter.quote(key, params));
        (bool success, bytes memory returnData) = address(implementation).delegatecall(msg.data);
        if (!success) {
            _handleRevert(returnData);
        }
        return abi.decode(returnData, (bytes4, BeforeSwapDelta, uint24));
    }

    function afterSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external returns (bytes4, int128) {
        IHooks implementation = IHooks(address(implementation));
        if (implementation.hasPermission(Hooks.BEFORE_SWAP_FLAG)) {
            int256 amountActual = params.zeroForOne == params.amountSpecified < 0 ? delta.amount1() : delta.amount0();
            if (amountActual != Quote.read()) revert HookModifiedOutput();
            Quote.reset();
            if (!implementation.hasPermission(Hooks.AFTER_SWAP_FLAG)) {
                return (BaseHook.afterSwap.selector, 0);
            }
        }
        (bool success, bytes memory returnData) = address(implementation).delegatecall(msg.data);
        if (!success) {
            _handleRevert(returnData);
        }
        return abi.decode(returnData, (bytes4, int128));
    }

    function _handleRevert(bytes memory returnData) internal pure {
        assembly {
            revert(add(32, returnData), mload(returnData))
        }
    }

    function _ensureValidFlags() internal view {
        IHooks This = IHooks(address(this));
        if (This.hasPermission(Hooks.BEFORE_SWAP_FLAG)) {
            if (
                uint160(address(this)) & Hooks.ALL_HOOK_MASK
                    != uint160(implementation) & Hooks.ALL_HOOK_MASK | Hooks.AFTER_SWAP_FLAG
            ) {
                if (IHooks(implementation).hasPermission(Hooks.AFTER_SWAP_FLAG)) {
                    revert FlagsMismatch();
                } else {
                    revert MustHaveAfterSwapFlagOnMiddleware();
                }
            }
        } else if (uint160(address(this)) & Hooks.ALL_HOOK_MASK != uint160(implementation) & Hooks.ALL_HOOK_MASK) {
            revert FlagsMismatch();
        }
        if (
            This.hasPermission(Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG)
                || This.hasPermission(Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG)
                || This.hasPermission(Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG)
                || This.hasPermission(Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG)
        ) {
            HookPermissionForbidden.selector.revertWith(address(this));
        }
    }
}
