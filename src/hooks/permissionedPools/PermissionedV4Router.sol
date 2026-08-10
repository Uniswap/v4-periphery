// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ActionConstants} from "../../libraries/ActionConstants.sol";
import {V4Router, IPoolManager, Currency, PoolKey} from "../../V4Router.sol";
import {IPermissionsAdapter} from "./interfaces/IPermissionsAdapter.sol";
import {IPermissionsAdapterFactory} from "./interfaces/IPermissionsAdapterFactory.sol";
import {PermissionFlags} from "./libraries/PermissionFlags.sol";

/// @title Abstract base for routers that support permissioned V4 pools
/// @notice Provides _pay and _mapSettleAmount overrides for wrapping/unwrapping permissioned tokens.
///         Concrete routers (e.g., UniversalRouter's V4SwapRouter) inherit this contract.
abstract contract PermissionedV4Router is V4Router {
    IPermissionsAdapterFactory public immutable PERMISSIONS_ADAPTER_FACTORY;

    error Unauthorized();
    error SwappingDisabled();
    error HookNotAllowed();

    constructor(IPoolManager poolManager_, IPermissionsAdapterFactory permissionsAdapterFactory)
        V4Router(poolManager_)
    {
        PERMISSIONS_ADAPTER_FACTORY = permissionsAdapterFactory;
    }

    /// @inheritdoc V4Router
    /// @dev Permission enforcement for a permissioned pool lives in its hook, so a pool holding a
    ///      verified adapter must not be swapped through unless the adapter's owner has allow-listed
    ///      that hook. Rejecting only `address(0)` is insufficient — a no-op hook, or an address mined
    ///      without `BEFORE_SWAP_FLAG`, would otherwise pass.
    function _validatePoolKey(PoolKey memory poolKey) internal view override {
        if (address(PERMISSIONS_ADAPTER_FACTORY) == address(0)) return;
        _validateHook(poolKey.currency0, poolKey.hooks);
        _validateHook(poolKey.currency1, poolKey.hooks);
    }

    /// @notice Reverts if `currency` is a verified permissions adapter that has not allow-listed `hooks`
    function _validateHook(Currency currency, IHooks hooks) internal view {
        if (PERMISSIONS_ADAPTER_FACTORY.verifiedPermissionsAdapterOf(Currency.unwrap(currency)) == address(0)) return;
        if (!IPermissionsAdapter(Currency.unwrap(currency)).allowedHooks(hooks)) revert HookNotAllowed();
    }

    function _take(Currency currency, address recipient, uint256 amount) internal virtual override {
        address permissionedToken = address(PERMISSIONS_ADAPTER_FACTORY) == address(0)
            ? address(0)
            : PERMISSIONS_ADAPTER_FACTORY.verifiedPermissionsAdapterOf(Currency.unwrap(currency));

        // If the token is permissioned, validate swapping is enabled and the sender is swap-allowed
        if (permissionedToken != address(0)) {
            IPermissionsAdapter permissionsAdapter = IPermissionsAdapter(Currency.unwrap(currency));
            if (!permissionsAdapter.swappingEnabled()) revert SwappingDisabled();
            if (!permissionsAdapter.isAllowed(msgSender(), PermissionFlags.SWAP_ALLOWED)) revert Unauthorized();
        }

        super._take(currency, recipient, amount);
    }

    function _pay(Currency currency, address payer, uint256 amount) internal virtual override {
        address permissionedToken = address(PERMISSIONS_ADAPTER_FACTORY) == address(0)
            ? address(0)
            : PERMISSIONS_ADAPTER_FACTORY.verifiedPermissionsAdapterOf(Currency.unwrap(currency));
        if (permissionedToken == address(0)) {
            _payStandard(currency, payer, amount);
            return;
        }
        // token is permissioned, wrap the token and transfer it to the pool manager
        IPermissionsAdapter permissionsAdapter = IPermissionsAdapter(Currency.unwrap(currency));
        if (!permissionsAdapter.swappingEnabled()) revert SwappingDisabled();
        if (!permissionsAdapter.isAllowed(msgSender(), PermissionFlags.SWAP_ALLOWED)) {
            revert Unauthorized();
        }
        if (payer == address(this)) {
            Currency.wrap(permissionedToken).transfer(address(permissionsAdapter), amount);
            permissionsAdapter.wrapToPoolManager(amount);
        } else {
            _payPermissionedFromPayer(payer, permissionsAdapter, permissionedToken, amount);
        }
    }

    /// @notice Hook for concrete routers to implement standard (non-permissioned) payment
    function _payStandard(Currency currency, address payer, uint256 amount) internal virtual;

    /// @notice Hook for concrete routers to implement payer-to-adapter transfer (e.g., via Permit2)
    function _payPermissionedFromPayer(
        address payer,
        IPermissionsAdapter permissionsAdapter,
        address permissionedToken,
        uint256 amount
    ) internal virtual;

    /// @notice Calculates the amount for a settle action
    function _mapSettleAmount(uint256 amount, Currency currency) internal view virtual override returns (uint256) {
        address permissionedToken = address(PERMISSIONS_ADAPTER_FACTORY) == address(0)
            ? address(0)
            : PERMISSIONS_ADAPTER_FACTORY.verifiedPermissionsAdapterOf(Currency.unwrap(currency));
        // use the default implementation unless the currency is a permissioned token with a balance on the router
        if (permissionedToken == address(0) || amount != ActionConstants.CONTRACT_BALANCE) {
            return super._mapSettleAmount(amount, currency);
        }
        return Currency.wrap(permissionedToken).balanceOfSelf();
    }
}
