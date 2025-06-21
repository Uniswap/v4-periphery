// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    PositionManager,
    PoolKey,
    IPoolManager,
    IAllowanceTransfer,
    IPositionDescriptor,
    IWETH9,
    Currency
} from "../../PositionManager.sol";
import {
    IWrappedPermissionedTokenFactory,
    IWrappedPermissionedToken
} from "./interfaces/IWrappedPermissionedTokenFactory.sol";
import {Hooks, IHooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IMsgSender} from "../../interfaces/IMsgSender.sol";

contract PermissionedPositionManager is PositionManager, IHooks {
    IWrappedPermissionedTokenFactory public immutable WRAPPED_TOKEN_FACTORY;
    address public immutable PERMISSIONED_SWAP_ROUTER;

    error HookNotImplemented();
    error InvalidHook();

    constructor(
        IPoolManager _poolManager,
        IAllowanceTransfer _permit2,
        uint256 _unsubscribeGasLimit,
        IPositionDescriptor _tokenDescriptor,
        IWETH9 _weth9,
        IWrappedPermissionedTokenFactory _wrappedTokenFactory,
        address _permissionedSwapRouter
    ) PositionManager(_poolManager, _permit2, _unsubscribeGasLimit, _tokenDescriptor, _weth9) {
        WRAPPED_TOKEN_FACTORY = _wrappedTokenFactory;
        PERMISSIONED_SWAP_ROUTER = _permissionedSwapRouter;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    /// @dev Disables transfers of the ERC721 liquidity position tokens
    function transferFrom(address, address, uint256) public pure override {
        revert("Transfer disabled");
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory permissions) {
        permissions.beforeSwap = true;
        permissions.beforeAddLiquidity = true;
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        returns (bytes4)
    {
        if (sender != address(this)) revert Unauthorized();
        _verifyAllowlist(IMsgSender(sender), key);
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @inheritdoc IHooks
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata, bytes calldata)
        external
        view
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (sender != PERMISSIONED_SWAP_ROUTER) revert Unauthorized();
        _verifyAllowlist(IMsgSender(sender), key);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev When minting a position, verify that the sender is allowed to mint the position. This prevents a disallowed user from minting one sided liquidity.
    function _mint(
        PoolKey calldata poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        address owner,
        bytes calldata hookData
    ) internal override {
        // allowlist is verified in the hook call
        if (poolKey.hooks != this) revert InvalidHook();
        super._mint(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, hookData);
    }

    /// @dev When paying to settle, if the currency is a permissioned token, wrap the token and transfer it to the pool manager.
    function _pay(Currency currency, address payer, uint256 amount) internal virtual override {
        address permissionedToken = WRAPPED_TOKEN_FACTORY.verifiedPermissionedTokenOf(Currency.unwrap(currency));
        if (permissionedToken == address(0)) {
            // token is not a permissioned token, use the default implementation
            super._pay(currency, payer, amount);
            return;
        }
        // token is a permissioned token, wrap the token
        IWrappedPermissionedToken wrappedPermissionedToken = IWrappedPermissionedToken(Currency.unwrap(currency));
        permit2.transferFrom(payer, address(wrappedPermissionedToken), uint160(amount), permissionedToken);
        wrappedPermissionedToken.wrapToPoolManager(amount);
    }

    function _verifyAllowlist(IMsgSender sender, PoolKey calldata poolKey) internal view {
        IWrappedPermissionedToken wrappedToken0 = IWrappedPermissionedToken(Currency.unwrap(poolKey.currency0));
        IWrappedPermissionedToken wrappedToken1 = IWrappedPermissionedToken(Currency.unwrap(poolKey.currency1));
        address permissionedToken0 = WRAPPED_TOKEN_FACTORY.verifiedPermissionedTokenOf(address(wrappedToken0));
        address permissionedToken1 = WRAPPED_TOKEN_FACTORY.verifiedPermissionedTokenOf(address(wrappedToken1));
        if (permissionedToken0 != address(0) && !wrappedToken0.isAllowed(sender.msgSender())) {
            revert Unauthorized();
        }
        if (permissionedToken1 != address(0) && !wrappedToken1.isAllowed(sender.msgSender())) {
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
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
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
