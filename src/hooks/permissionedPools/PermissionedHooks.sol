// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager, Currency} from "../../V4Router.sol";
import {IPermissionsAdapter} from "./interfaces/IPermissionsAdapter.sol";
import {IPermissionsAdapterFactory} from "./interfaces/IPermissionsAdapterFactory.sol";
import {IMsgSender} from "../../interfaces/IMsgSender.sol";
import {ReentrancyLock} from "../../base/ReentrancyLock.sol";
import {Hooks, IHooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BaseHook} from "../../utils/BaseHook.sol";
import {PermissionFlags, PermissionFlag} from "./libraries/PermissionFlags.sol";

contract PermissionedHooks is IHooks, ReentrancyLock, BaseHook {
    using StateLibrary for IPoolManager;

    IPermissionsAdapterFactory public immutable PERMISSIONS_ADAPTER_FACTORY;

    /// @notice Emitted after a swap through a permissioned pool. Mirrors `IV4Router.Swap` so that
    /// indexers can track swaps on permissioned pools with the same schema as the standard router.
    /// @param id The pool the swap occurred on
    /// @param sender The originator of the swap
    /// @param amount0 The signed change in currency0 balance from the pool's perspective
    /// @param amount1 The signed change in currency1 balance from the pool's perspective
    /// @param sqrtPriceX96 The pool's sqrt price after the swap
    /// @param liquidity The pool's active liquidity after the swap
    /// @param tick The pool's tick after the swap
    /// @param fee The pool's swap fee at the time of the swap
    event Swap(
        PoolId indexed id,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick,
        uint24 fee
    );

    error Unauthorized();
    error SwappingDisabled();
    error NoVerifiedAdapter();
    error UnverifiedAdapter();

    constructor(IPoolManager manager, IPermissionsAdapterFactory permissionsAdapterFactory) BaseHook(manager) {
        PERMISSIONS_ADAPTER_FACTORY = permissionsAdapterFactory;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    /// @dev Returns the hook permissions configuration for this contract
    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = true;
        permissions.beforeSwap = true;
        permissions.afterSwap = true;
        permissions.beforeAddLiquidity = true;
    }

    /// @dev Requires at least one pool currency to be a verified permissions adapter, and disallows
    /// any pool currency that is an unverified permissions adapter.
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);

        bool currency0IsAdapter = PERMISSIONS_ADAPTER_FACTORY.permissionsAdapterOf(currency0) != address(0);
        bool currency1IsAdapter = PERMISSIONS_ADAPTER_FACTORY.permissionsAdapterOf(currency1) != address(0);

        if (!currency0IsAdapter && !currency1IsAdapter) revert NoVerifiedAdapter();
        if (currency0IsAdapter && PERMISSIONS_ADAPTER_FACTORY.verifiedPermissionsAdapterOf(currency0) == address(0)) {
            revert UnverifiedAdapter();
        }
        if (currency1IsAdapter && PERMISSIONS_ADAPTER_FACTORY.verifiedPermissionsAdapterOf(currency1) == address(0)) {
            revert UnverifiedAdapter();
        }

        return IHooks.beforeInitialize.selector;
    }

    /// @dev Does not need to verify msg.sender address directly, as verifying the allowlist is sufficient due to the fact that any valid senders are allowed wrappers
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4 selector, BeforeSwapDelta, uint24)
    {
        selector = IHooks.beforeSwap.selector;
        _verifyAllowlist(IMsgSender(sender), key, selector);
        return (selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev Emits a Swap event so indexers can track activity on permissioned pools.
    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        (uint160 sqrtPriceX96, int24 tick,, uint24 fee) = poolManager.getSlot0(id);
        uint128 liquidity = poolManager.getLiquidity(id);
        emit Swap(
            id, IMsgSender(sender).msgSender(), delta.amount0(), delta.amount1(), sqrtPriceX96, liquidity, tick, fee
        );
        return (IHooks.afterSwap.selector, 0);
    }

    /// @dev Does not need to verify msg.sender address directly, as verifying the allowlist is sufficient due to the fact that any valid senders are allowed wrappers
    function _beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4 selector)
    {
        selector = IHooks.beforeAddLiquidity.selector;
        _verifyAllowlist(IMsgSender(sender), key, selector);
    }

    /// @dev checks if the sender is allowed to access both tokens in the pool
    function _verifyAllowlist(IMsgSender sender, PoolKey calldata poolKey, bytes4 selector) internal view {
        _isAllowed(Currency.unwrap(poolKey.currency0), sender.msgSender(), address(sender), selector);
        _isAllowed(Currency.unwrap(poolKey.currency1), sender.msgSender(), address(sender), selector);
    }

    /// @dev checks if the provided token is a permissioned token by checking if it has a verified permissions adapter, if yes, check the allowlist and check whether swapping is enabled
    function _isAllowed(address permissionsAdapter, address sender, address router, bytes4 selector) internal view {
        address permissionedToken = PERMISSIONS_ADAPTER_FACTORY.verifiedPermissionsAdapterOf(permissionsAdapter);
        if (permissionedToken == address(0)) return;

        PermissionFlag permission = PermissionFlags.NONE;
        if (selector == this.beforeSwap.selector) {
            permission = PermissionFlags.SWAP_ALLOWED;
            if (!IPermissionsAdapter(permissionsAdapter).swappingEnabled()) revert SwappingDisabled();
        } else if (selector == this.beforeAddLiquidity.selector) {
            permission = PermissionFlags.LIQUIDITY_ALLOWED;
        }

        if (
            !IPermissionsAdapter(permissionsAdapter).isAllowed(sender, permission)
                || !IPermissionsAdapter(permissionsAdapter).allowedWrappers(router)
        ) revert Unauthorized();
    }
}
