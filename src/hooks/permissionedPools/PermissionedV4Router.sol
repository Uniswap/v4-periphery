// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {V4Router, IPoolManager, Currency} from "../../V4Router.sol";
import {ReentrancyLock} from "../../base/ReentrancyLock.sol";
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
import {console2} from "forge-std/console2.sol";

contract PermissionedV4Router is V4Router, ReentrancyLock, IHooks {
    IAllowanceTransfer public immutable PERMIT2;
    IWrappedPermissionedTokenFactory public immutable WRAPPED_TOKEN_FACTORY;
    address public immutable PERMISSIONED_POSITION_MANAGER;

    error Unauthorized();
    error HookNotImplemented();

    /// @dev as this contract and the swap router rely on each others addresses in the constructor, both contracts need
    /// to be deployed using create3 to create deterministic addresses that do not depend on the constructor arguments
    constructor(
        IPoolManager poolManager_,
        IAllowanceTransfer _permit2,
        IWrappedPermissionedTokenFactory wrappedTokenFactory,
        address permissionedPositionManager // address needs to be calculated in advance using create3
    ) V4Router(poolManager_) {
        PERMIT2 = _permit2;
        WRAPPED_TOKEN_FACTORY = wrappedTokenFactory;
        PERMISSIONED_POSITION_MANAGER = permissionedPositionManager;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    function execute(bytes calldata input) public payable isNotLocked {
        _executeActions(input);
    }

    /// @notice Public view function to be used instead of msg.sender, as the contract performs self-reentrancy and at
    /// times msg.sender == address(this). Instead msgSender() returns the initiator of the lock
    /// @dev overrides BaseActionsRouter.msgSender in V4Router
    function msgSender() public view override returns (address) {
        return _getLocker();
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
        if (sender != address(this)) revert Unauthorized();
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

    function _pay(Currency currency, address payer, uint256 amount) internal override {
        address permissionedToken = WRAPPED_TOKEN_FACTORY.verifiedPermissionedTokenOf(Currency.unwrap(currency));
        if (permissionedToken == address(0)) {
            // token is not a permissioned token, use the default implementation
            if (payer == address(this)) {
                currency.transfer(address(poolManager), amount);
            } else {
                // Casting from uint256 to uint160 is safe due to limits on the total supply of a pool
                PERMIT2.transferFrom(payer, address(poolManager), uint160(amount), Currency.unwrap(currency));
            }
            return;
        }

        // token is permissioned, wrap the token and transfer it to the pool manager
        IWrappedPermissionedToken wrappedPermissionedToken = IWrappedPermissionedToken(Currency.unwrap(currency));
        if (payer == address(this)) {
            // allowlist check necessary to ensure a disallowed user cannot sell a permissioned token
            if (!wrappedPermissionedToken.isAllowed(msgSender())) {
                revert Unauthorized();
            }
            currency.transfer(address(wrappedPermissionedToken), amount);
            wrappedPermissionedToken.wrapToPoolManager(amount);
        } else {
            // token is a permissioned token, wrap the token
            PERMIT2.transferFrom(payer, address(wrappedPermissionedToken), uint160(amount), permissionedToken);
            wrappedPermissionedToken.wrapToPoolManager(amount);
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
