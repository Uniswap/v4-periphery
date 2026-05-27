// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Hooks, IHooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IMsgSender} from "../../../../src/interfaces/IMsgSender.sol";
import {IPermissionsAdapter} from "../../../../src/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {
    IPermissionsAdapterFactory
} from "../../../../src/hooks/permissionedPools/interfaces/IPermissionsAdapterFactory.sol";
import {PermissionFlags, PermissionFlag} from "../../../../src/hooks/permissionedPools/libraries/PermissionFlags.sol";

/// @notice Standalone mock that replicates PermissionedHooks logic without inheriting BaseHook
contract MockPermissionedHooks {
    using StateLibrary for IPoolManager;

    error Unauthorized();
    error SwappingDisabled();
    error NoVerifiedAdapter();
    error UnverifiedAdapter();
    error HookNotImplemented();

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

    IPoolManager public immutable manager;
    IPermissionsAdapterFactory public immutable PERMISSIONS_ADAPTER_FACTORY;

    constructor(IPoolManager _manager, IPermissionsAdapterFactory _permissionsAdapterFactory) {
        manager = _manager;
        PERMISSIONS_ADAPTER_FACTORY = _permissionsAdapterFactory;
    }

    function beforeInitialize(address, PoolKey calldata key, uint160) external view returns (bytes4) {
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

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata, bytes calldata)
        external
        view
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _verifyAllowlist(IMsgSender(sender), key, IHooks.beforeSwap.selector);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        returns (bytes4)
    {
        _verifyAllowlist(IMsgSender(sender), key, IHooks.beforeAddLiquidity.selector);
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterSwap(address sender, PoolKey calldata key, SwapParams calldata, BalanceDelta delta, bytes calldata)
        external
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        (uint160 sqrtPriceX96, int24 tick,, uint24 fee) = manager.getSlot0(id);
        uint128 liquidity = manager.getLiquidity(id);
        emit Swap(
            id, IMsgSender(sender).msgSender(), delta.amount0(), delta.amount1(), sqrtPriceX96, liquidity, tick, fee
        );
        return (IHooks.afterSwap.selector, 0);
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

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

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function _verifyAllowlist(IMsgSender sender, PoolKey calldata poolKey, bytes4 selector) internal view {
        _isAllowed(Currency.unwrap(poolKey.currency0), sender.msgSender(), address(sender), selector);
        _isAllowed(Currency.unwrap(poolKey.currency1), sender.msgSender(), address(sender), selector);
    }

    function _isAllowed(address permissionsAdapter, address sender, address router, bytes4 selector) internal view {
        address permissionedToken = PERMISSIONS_ADAPTER_FACTORY.verifiedPermissionsAdapterOf(permissionsAdapter);
        if (permissionedToken == address(0)) return;

        PermissionFlag permission = PermissionFlags.NONE;
        if (selector == IHooks.beforeSwap.selector) {
            permission = PermissionFlags.SWAP_ALLOWED;
            if (!IPermissionsAdapter(permissionsAdapter).swappingEnabled()) revert SwappingDisabled();
        } else if (selector == IHooks.beforeAddLiquidity.selector) {
            permission = PermissionFlags.LIQUIDITY_ALLOWED;
        }

        if (
            !IPermissionsAdapter(permissionsAdapter).isAllowed(sender, permission)
                || !IPermissionsAdapter(permissionsAdapter).allowedWrappers(router)
        ) revert Unauthorized();
    }
}
