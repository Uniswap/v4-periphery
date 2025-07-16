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
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract PermissionedPositionManager is PositionManager {
    IWrappedPermissionedTokenFactory public immutable WRAPPED_TOKEN_FACTORY;
    IHooks public immutable PERMISSIONED_HOOKS;

    error InvalidHook();
    error SafeTransferDisabled();

    /// @dev as this contract must know the hooks address in advance, it must be passed in as a constructor argument
    constructor(
        IPoolManager _poolManager,
        IAllowanceTransfer _permit2,
        uint256 _unsubscribeGasLimit,
        IPositionDescriptor _tokenDescriptor,
        IWETH9 _weth9,
        IWrappedPermissionedTokenFactory _wrappedTokenFactory,
        IHooks _permissionedHooks
    ) PositionManager(_poolManager, _permit2, _unsubscribeGasLimit, _tokenDescriptor, _weth9) {
        WRAPPED_TOKEN_FACTORY = _wrappedTokenFactory;
        PERMISSIONED_HOOKS = _permissionedHooks;
    }

    /// @dev Only allow admins of permissioned tokens to transfer positions that contain their tokens
    function transferFrom(address from, address to, uint256 id) public override onlyIfPoolManagerLocked {
        (PoolKey memory poolKey,) = getPoolAndPositionInfo(id);
        address admin1 = _getOwner(poolKey.currency0);
        address admin2 = _getOwner(poolKey.currency1);
        if (msg.sender != admin1 && msg.sender != admin2) {
            revert Unauthorized();
        }
        getApproved[id] = msg.sender;
        super.transferFrom(from, to, id);
    }

    function safeTransferFrom(address, address, uint256) public pure override {
        revert SafeTransferDisabled();
    }

    function safeTransferFrom(address, address, uint256, bytes calldata) public pure override {
        revert SafeTransferDisabled();
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
        if (poolKey.hooks != PERMISSIONED_HOOKS) revert InvalidHook();
        super._mint(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, hookData);
    }

    /// @dev When paying to settle, if the currency is a permissioned token, wrap the token and transfer it to the pool manager.
    function _pay(Currency currency, address payer, uint256 amount) internal virtual override {
        address permissionedToken = _verifiedPermissionedTokenOf(currency);
        if (permissionedToken == address(0)) {
            // token is not a permissioned token, use the default implementation
            super._pay(currency, payer, amount);
            return;
        }
        // token is permissioned, wrap the token and transfer it to the pool manager
        IWrappedPermissionedToken wrappedPermissionedToken = IWrappedPermissionedToken(Currency.unwrap(currency));
        if (payer == address(this)) {
            // @audit is it necessary to check the allowlist here?
            if (!wrappedPermissionedToken.isAllowed(msgSender())) {
                revert Unauthorized();
            }
            Currency.wrap(permissionedToken).transfer(address(wrappedPermissionedToken), amount);
            wrappedPermissionedToken.wrapToPoolManager(amount);
        } else {
            // token is a permissioned token, wrap the token
            permit2.transferFrom(payer, address(wrappedPermissionedToken), uint160(amount), permissionedToken);
            wrappedPermissionedToken.wrapToPoolManager(amount);
        }
    }

    function _verifiedPermissionedTokenOf(Currency currency) internal view returns (address) {
        return WRAPPED_TOKEN_FACTORY.verifiedPermissionedTokenOf(Currency.unwrap(currency));
    }

    function _getOwner(Currency currency) internal view returns (address) {
        address wrappedPermissionedToken = Currency.unwrap(currency);
        address permissionedToken = _verifiedPermissionedTokenOf(currency);
        if (permissionedToken == address(0)) return address(0);
        return IWrappedPermissionedToken(wrappedPermissionedToken).owner();
    }
}
