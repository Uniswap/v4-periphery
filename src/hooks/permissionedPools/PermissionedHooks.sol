// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager, Currency} from "../../V4Router.sol";
import {IPermissionsAdapter} from "./interfaces/IPermissionsAdapter.sol";
import {IPermissionsAdapterFactory} from "./interfaces/IPermissionsAdapterFactory.sol";
import {IMsgSender} from "../../interfaces/IMsgSender.sol";
import {ReentrancyLock} from "../../base/ReentrancyLock.sol";
import {Hooks, IHooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BaseHook} from "../../utils/BaseHook.sol";
import {PermissionFlags, PermissionFlag} from "./libraries/PermissionFlags.sol";

contract PermissionedHooks is IHooks, ReentrancyLock, BaseHook {
    IPermissionsAdapterFactory public immutable PERMISSIONS_ADAPTER_FACTORY;

    error Unauthorized();
    error SwappingDisabled();

    constructor(IPoolManager manager, IPermissionsAdapterFactory permissionsAdapterFactory) BaseHook(manager) {
        PERMISSIONS_ADAPTER_FACTORY = permissionsAdapterFactory;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    /// @dev Returns the hook permissions configuration for this contract
    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.beforeSwap = true;
        permissions.beforeAddLiquidity = true;
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
    function _isAllowed(address pemissionsAdapter, address sender, address router, bytes4 selector) internal view {
        address permissionedToken = PERMISSIONS_ADAPTER_FACTORY.verifiedPermissionsAdapterOf(pemissionsAdapter);
        if (permissionedToken == address(0)) return;

        PermissionFlag permission = PermissionFlags.NONE;
        if (selector == this.beforeSwap.selector) {
            permission = PermissionFlags.SWAP_ALLOWED;
            if (!IPermissionsAdapter(pemissionsAdapter).swappingEnabled()) revert SwappingDisabled();
        } else if (selector == this.beforeAddLiquidity.selector) {
            permission = PermissionFlags.LIQUIDITY_ALLOWED;
        }

        if (
            !IPermissionsAdapter(pemissionsAdapter).isAllowed(sender, permission)
                || !IPermissionsAdapter(pemissionsAdapter).allowedWrappers(router)
        ) revert Unauthorized();
    }
}
