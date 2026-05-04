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
import {ActionConstants} from "../../libraries/ActionConstants.sol";
import {Actions} from "../../libraries/Actions.sol";
import {CalldataDecoder} from "../../libraries/CalldataDecoder.sol";

contract PermissionedPositionManager is PositionManager {
    using CalldataDecoder for bytes;

    /// @dev Takes a currency's positive delta with a fallback cascade: LP → defaultRecipient → 6909 mint to
    ///      defaultRecipient. Picked above the standard Actions.sol range to avoid collision.
    uint256 private constant _ACTION_TAKE_WITH_FALLBACK = 0x20;

    IPermissionsAdapterFactory public immutable PERMISSIONS_ADAPTER_FACTORY;

    mapping(Currency currency => mapping(IHooks hooks => bool)) public isAllowedHooks;

    event AllowedHooksUpdated(Currency currency, IHooks hooks, bool allowed);
    event PositionUnwound(
        uint256 indexed tokenId, address indexed lp, address indexed admin, address defaultRecipient
    );
    event ClaimWithdrawn(Currency indexed currency, address indexed from, address indexed to, uint256 amount);

    error InvalidHook();
    error TransferDisabled();
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
        /// @dev The EIP712 domain separator still uses "Uniswap v4 Positions NFT" as the name
        name = "Uniswap v4 Permissioned Positions NFT";
        symbol = "UNI-V4-PERM-POSM";
    }

    /// @notice Sets the allowed hook for a given permissions adapter
    /// @dev Sets which hooks are allowed to be used with a permissions adapter. Only callable by the owner of the permissions adapter.
    ///      Revoking a hook (setting `allowed` to false) blocks future mints and liquidity increases on existing positions that use
    ///      that hook; existing liquidity can still be decreased or burned so that holders can always exit.
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

    /// @notice Force-exit the LP from a position. Burns the NFT, unwinds liquidity, and routes each currency.
    /// @dev Either PA admin in the pool may call. For each currency the cascade is: try transfer to the original
    ///      LP → on failure, try transfer to `defaultRecipient` → on failure, mint a persistent ERC-6909 claim on
    ///      the PoolManager to `defaultRecipient`. The third step never reverts, so the call is atomic. Permissioned
    ///      currencies unwrap to the underlying token; non-permissioned currencies transfer directly.
    /// @param tokenId          The position to unwind
    /// @param defaultRecipient The fallback address used if the LP cannot receive a currency
    function unwindPosition(uint256 tokenId, address defaultRecipient) external isNotLocked {
        (PoolKey memory poolKey,) = getPoolAndPositionInfo(tokenId);
        address admin0 = _getOwner(poolKey.currency0);
        address admin1 = _getOwner(poolKey.currency1);
        if (msg.sender != admin0 && msg.sender != admin1) revert Unauthorized();

        address lp = ownerOf(tokenId);
        emit PositionUnwound(tokenId, lp, msg.sender, defaultRecipient);

        // Pre-approve so BURN_POSITION inside the unlock passes its onlyIfApproved check.
        // ERC-721 _burn clears getApproved as part of its teardown, so the approval is self-cleaning.
        getApproved[tokenId] = msg.sender;

        bytes memory actions = abi.encodePacked(
            uint8(Actions.BURN_POSITION), uint8(_ACTION_TAKE_WITH_FALLBACK), uint8(_ACTION_TAKE_WITH_FALLBACK)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(tokenId, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(poolKey.currency0, lp, defaultRecipient);
        params[2] = abi.encode(poolKey.currency1, lp, defaultRecipient);
        poolManager.unlock(abi.encode(actions, params));
    }

    /// @notice Burn an ERC-6909 claim on the PoolManager and transfer the underlying currency to `to`.
    /// @dev Caller must hold the claim or have called PoolManager.setOperator(permPosm, true). For permissioned
    ///      currencies, `to` must clear the underlying token's issuer compliance on unwrap. `to` follows the
    ///      standard `Actions.TAKE` recipient sentinels: `address(1)` remaps to the caller, `address(2)` to this
    ///      contract.
    function withdrawClaim(Currency currency, uint256 amount, address to) external isNotLocked {
        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_6909), uint8(Actions.TAKE));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(currency, msg.sender, amount);
        params[1] = abi.encode(currency, to, amount);
        emit ClaimWithdrawn(currency, msg.sender, to, amount);
        poolManager.unlock(abi.encode(actions, params));
    }

    /// @inheritdoc PositionManager
    /// @dev Positions of permissioned tokens are not transferable.
    function transferFrom(address from, address to, uint256 id) public override onlyIfPoolManagerLocked {
        revert TransferDisabled();
    }

    function safeTransferFrom(address, address, uint256) public pure override {
        revert TransferDisabled();
    }

    function safeTransferFrom(address, address, uint256, bytes calldata) public pure override {
        revert TransferDisabled();
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
        _checkRecipientAllowed(poolKey.currency0, owner);
        _checkRecipientAllowed(poolKey.currency1, owner);
        super._mint(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, hookData);
    }

    /// @dev Re-validate the hook allowlist on every liquidity increase so that a revoked hook cannot
    ///      continue to accept new inflows on existing positions. Decrease and burn paths are intentionally
    ///      left unchecked so that holders can always exit positions even after a hook has been removed
    ///      from the allowlist.
    function _increase(
        uint256 tokenId,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        bytes calldata hookData
    ) internal override {
        (PoolKey memory poolKey,) = getPoolAndPositionInfo(tokenId);
        if (!_checkAllowedHooks(poolKey)) revert InvalidHook();
        super._increase(tokenId, liquidity, amount0Max, amount1Max, hookData);
    }

    /// @dev See `_increase` — same rationale for the from-deltas variant.
    function _increaseFromDeltas(uint256 tokenId, uint128 amount0Max, uint128 amount1Max, bytes calldata hookData)
        internal
        override
    {
        (PoolKey memory poolKey,) = getPoolAndPositionInfo(tokenId);
        if (!_checkAllowedHooks(poolKey)) revert InvalidHook();
        super._increaseFromDeltas(tokenId, amount0Max, amount1Max, hookData);
    }

    function _checkRecipientAllowed(Currency currency, address recipient) internal view {
        address permissionedToken = _verifiedPermissionedTokenOf(currency);
        if (permissionedToken == address(0)) return;
        if (!IPermissionsAdapter(Currency.unwrap(currency)).isAllowed(recipient, PermissionFlags.LIQUIDITY_ALLOWED)) {
            revert Unauthorized();
        }
    }

    function _checkAllowedHooks(PoolKey memory poolKey) internal view returns (bool) {
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
            // Check liquidity permission for the actual user
            if (!permissionsAdapter.isAllowed(msgSender(), PermissionFlags.LIQUIDITY_ALLOWED)) {
                revert Unauthorized();
            }
            Currency.wrap(permissionedToken).transfer(address(permissionsAdapter), amount);
            permissionsAdapter.wrapToPoolManager(amount);
        } else {
            // Check liquidity permission for the actual user
            if (!permissionsAdapter.isAllowed(msgSender(), PermissionFlags.LIQUIDITY_ALLOWED)) {
                revert Unauthorized();
            }
            // token is a permissioned token, wrap the token
            permit2.transferFrom(payer, address(permissionsAdapter), uint160(amount), permissionedToken);
            permissionsAdapter.wrapToPoolManager(amount);
        }
    }

    function _verifiedPermissionedTokenOf(Currency currency) internal view returns (address) {
        return PERMISSIONS_ADAPTER_FACTORY.verifiedPermissionsAdapterOf(Currency.unwrap(currency));
    }

    /// @notice Calculates the amount for a settle action
    function _mapSettleAmount(uint256 amount, Currency currency) internal view override returns (uint256) {
        address permissionedToken = _verifiedPermissionedTokenOf(currency);
        if (permissionedToken == address(0) || amount != ActionConstants.CONTRACT_BALANCE) {
            return super._mapSettleAmount(amount, currency);
        }
        return Currency.wrap(permissionedToken).balanceOfSelf();
    }

    function _getOwner(Currency currency) internal view returns (address) {
        address permissionsAdapter = Currency.unwrap(currency);
        address permissionedToken = _verifiedPermissionedTokenOf(currency);
        if (permissionedToken == address(0)) return address(0);
        return IPermissionsAdapter(permissionsAdapter).owner();
    }

    /// @dev Adds the cascade-routing action used by `unwindPosition` and the BURN_6909 primitive used by
    ///      `withdrawClaim`. All other actions fall through to the base PositionManager dispatcher.
    function _handleAction(uint256 action, bytes calldata params) internal override {
        if (action == _ACTION_TAKE_WITH_FALLBACK) {
            (Currency currency, address lp, address defaultRecipient) =
                abi.decode(params, (Currency, address, address));
            _routeCredit(currency, lp, defaultRecipient);
            return;
        }
        if (action == Actions.BURN_6909) {
            (Currency currency, address from, uint256 amount) = params.decodeCurrencyAddressAndUint256();
            poolManager.burn(from, currency.toId(), amount);
            return;
        }
        super._handleAction(action, params);
    }

    /// @dev Cascading routes: 1. Underlying -> LP, Underlying -> defaultRecipient, PA 6909 claim to defaultRecipient. Final mint never reverts.
    function _routeCredit(Currency currency, address lp, address defaultRecipient) internal {
        uint256 amount = _getFullCredit(currency);
        if (amount == 0) return;

        // Unwrap and transfer underlying to LP
        try poolManager.take(currency, lp, amount) {
            return;
        } catch {}
        // Unwrap and transfer underlying to defaultRecipient
        try poolManager.take(currency, defaultRecipient, amount) {
            return;
        } catch {}
        // Mint 6909 claim to defaultRecipient
        poolManager.mint(defaultRecipient, currency.toId(), amount);
    }
}
