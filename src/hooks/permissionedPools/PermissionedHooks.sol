// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager, Currency} from "../../V4Router.sol";
import {
    IWrappedPermissionedTokenFactory,
    IWrappedPermissionedToken
} from "./interfaces/IWrappedPermissionedTokenFactory.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Hooks, IHooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IMsgSender} from "../../interfaces/IMsgSender.sol";
import {ActionConstants} from "../../libraries/ActionConstants.sol";
import {ReentrancyLock} from "../../base/ReentrancyLock.sol";

contract PermissionedHooks is IHooks, ReentrancyLock {
    IWrappedPermissionedTokenFactory public immutable WRAPPED_TOKEN_FACTORY;
    address public immutable PERMISSIONED_POSITION_MANAGER;

    address public PERMISSIONED_ROUTER;

    error Unauthorized();
    error HookNotImplemented();

    /// @dev as this contract and the swap router rely on each others addresses in the constructor, both contracts need
    /// to be deployed using create3 to create deterministic addresses that do not depend on the constructor arguments
    constructor(
        IWrappedPermissionedTokenFactory wrappedTokenFactory,
        address permissionedPositionManager, // address needs to be calculated in advance using create3
        address permissionedRouter
    ) {
        WRAPPED_TOKEN_FACTORY = wrappedTokenFactory;
        PERMISSIONED_POSITION_MANAGER = permissionedPositionManager;
        PERMISSIONED_ROUTER = permissionedRouter;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory permissions) {
        permissions.beforeSwap = true;
        permissions.beforeAddLiquidity = true;
    }

    /// @inheritdoc IHooks
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata, bytes calldata)
        external
        view
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (sender != PERMISSIONED_ROUTER) revert Unauthorized();
        _verifyAllowlist(IMsgSender(sender), key);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        returns (bytes4)
    {
        if (sender != PERMISSIONED_POSITION_MANAGER) revert Unauthorized();
        _verifyAllowlist(IMsgSender(sender), key);
        return IHooks.beforeAddLiquidity.selector;
    }

    function _verifyAllowlist(IMsgSender sender, PoolKey calldata poolKey) internal view {
        _isAllowed(Currency.unwrap(poolKey.currency0), sender.msgSender());
        _isAllowed(Currency.unwrap(poolKey.currency1), sender.msgSender());
    }

    /// @dev checks if the provided token is a wrapped token by checking if it has a verified permissioned token, if yes, check the allowlist
    function _isAllowed(address wrappedToken, address sender) internal view {
        address permissionedToken = WRAPPED_TOKEN_FACTORY.verifiedPermissionedTokenOf(wrappedToken);
        if (permissionedToken == address(0)) return;
        if (!IWrappedPermissionedToken(wrappedToken).isAllowed(sender)) {
            revert Unauthorized();
        }
    }

    /// @inheritdoc IHooks
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
