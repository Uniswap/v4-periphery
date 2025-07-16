// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager, Currency} from "../../V4Router.sol";
import {
    IWrappedPermissionedTokenFactory,
    IWrappedPermissionedToken
} from "./interfaces/IWrappedPermissionedTokenFactory.sol";
import {IMsgSender} from "../../interfaces/IMsgSender.sol";
import {ReentrancyLock} from "../../base/ReentrancyLock.sol";
import {Hooks, IHooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BaseHook} from "../../utils/BaseHook.sol";
import {PermissionFlags, PermissionFlag} from "./libraries/PermissionFlags.sol";

contract PermissionedHooks is IHooks, ReentrancyLock, BaseHook {
    IWrappedPermissionedTokenFactory public immutable WRAPPED_TOKEN_FACTORY;

    error Unauthorized();
    error SwappingDisabled();

    constructor(IPoolManager manager, IWrappedPermissionedTokenFactory wrappedTokenFactory) BaseHook(manager) {
        WRAPPED_TOKEN_FACTORY = wrappedTokenFactory;
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

    /// @dev checks if the provided token is a wrapped token by checking if it has a verified permissioned token, if yes, check the allowlist and check whether swapping is enabled
    function _isAllowed(address wrappedToken, address sender, address router, bytes4 selector) internal view {
        address permissionedToken = WRAPPED_TOKEN_FACTORY.verifiedPermissionedTokenOf(wrappedToken);
        if (permissionedToken == address(0)) return;

        PermissionFlag permission = PermissionFlags.NONE;
        if (selector == this.beforeSwap.selector) {
            permission = PermissionFlags.SWAP_ALLOWED;
            if (!IWrappedPermissionedToken(wrappedToken).swappingEnabled()) revert SwappingDisabled();
        } else if (selector == this.beforeAddLiquidity.selector) {
            permission = PermissionFlags.LIQUIDITY_ALLOWED;
        }

        if (
            !IWrappedPermissionedToken(wrappedToken).isAllowed(sender, permission)
                || !IWrappedPermissionedToken(wrappedToken).allowedWrappers(router)
        ) revert Unauthorized();
    }
}
