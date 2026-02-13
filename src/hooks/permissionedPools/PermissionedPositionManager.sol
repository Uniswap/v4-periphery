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
import {IPermissionsAdapter} from "./interfaces/IPermissionsAdapter.sol";
import {IPermissionsAdapterFactory} from "./interfaces/IPermissionsAdapterFactory.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PermissionFlags} from "./libraries/PermissionFlags.sol";

contract PermissionedPositionManager is PositionManager {
    IPermissionsAdapterFactory public immutable PERMISSIONS_ADAPTER_FACTORY;

    mapping(Currency currency => mapping(IHooks hooks => bool)) public isAllowedHooks;

    event AllowedHooksUpdated(Currency currency, IHooks hooks, bool allowed);

    error InvalidHook();
    error SafeTransferDisabled();
    error NotPermissionsAdapterAdmin();

    /// @dev as this contract must know the hooks address in advance, it must be passed in as a constructor argument
    constructor(
        IPoolManager _poolManager,
        IAllowanceTransfer _permit2,
        uint256 _unsubscribeGasLimit,
        IPositionDescriptor _tokenDescriptor,
        IWETH9 _weth9,
        IPermissionsAdapterFactory _permissionsAdapterFactory
    ) PositionManager(_poolManager, _permit2, _unsubscribeGasLimit, _tokenDescriptor, _weth9) {
        PERMISSIONS_ADAPTER_FACTORY = _permissionsAdapterFactory;
    }

    /// @notice Sets the allowed hook for a given permissions adapter
    /// @dev Sets which hooks are allowed to be used with a permissions adapter. Only callable by the owner of the permissions adapter
    /// @param currency The currency of the permissions adapter
    /// @param hooks The hook to set the allowance for
    /// @param allowed Whether the hook is allowed to be used with the permissions adapter
    function setAllowedHook(Currency currency, IHooks hooks, bool allowed) external {
        if (_getOwner(currency) != msg.sender) {
            revert NotPermissionsAdapterAdmin();
        }
        bool oldAllowed = isAllowedHooks[currency][hooks];
        if (oldAllowed == allowed) return;
        isAllowedHooks[currency][hooks] = allowed;
        emit AllowedHooksUpdated(currency, hooks, allowed);
    }

    /// @inheritdoc PositionManager
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
        if (!_checkAllowedHooks(poolKey)) revert InvalidHook();
        super._mint(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, hookData);
    }

    function _checkAllowedHooks(PoolKey calldata poolKey) internal view returns (bool) {
        return
            _checkAllowedHook(poolKey.currency0, poolKey.hooks) && _checkAllowedHook(poolKey.currency1, poolKey.hooks);
    }

    function _checkAllowedHook(Currency currency, IHooks hooks) internal view returns (bool) {
        address permissionedToken = _verifiedPermissionedTokenOf(currency);
        if (permissionedToken == address(0)) return true;
        return isAllowedHooks[currency][hooks];
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
        IPermissionsAdapter permissionsAdapter = IPermissionsAdapter(Currency.unwrap(currency));
        if (payer == address(this)) {
            // @audit is it necessary to check the allowlist here?
            if (!permissionsAdapter.isAllowed(msgSender(), PermissionFlags.LIQUIDITY_ALLOWED)) {
                revert Unauthorized();
            }
            Currency.wrap(permissionedToken).transfer(address(permissionsAdapter), amount);
            permissionsAdapter.wrapToPoolManager(amount);
        } else {
            // token is a permissioned token, wrap the token
            permit2.transferFrom(payer, address(permissionsAdapter), uint160(amount), permissionedToken);
            permissionsAdapter.wrapToPoolManager(amount);
        }
    }

    function _verifiedPermissionedTokenOf(Currency currency) internal view returns (address) {
        return PERMISSIONS_ADAPTER_FACTORY.verifiedPermissionsAdapterOf(Currency.unwrap(currency));
    }

    function _getOwner(Currency currency) internal view returns (address) {
        address permissionsAdapter = Currency.unwrap(currency);
        address permissionedToken = _verifiedPermissionedTokenOf(currency);
        if (permissionedToken == address(0)) return address(0);
        return IPermissionsAdapter(permissionsAdapter).owner();
    }
}
