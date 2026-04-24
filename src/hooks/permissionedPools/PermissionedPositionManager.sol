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

    IPermissionsAdapterFactory public immutable PERMISSIONS_ADAPTER_FACTORY;

    mapping(Currency currency => mapping(IHooks hooks => bool)) public isAllowedHooks;

    event AllowedHooksUpdated(Currency currency, IHooks hooks, bool allowed);
    event PositionSeized(
        uint256 indexed tokenId,
        address indexed previousOwner,
        address indexed seizingAdmin,
        address recipient0,
        address recipient1
    );

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

    /// @notice Atomically retire a position and convert each currency's proceeds into an ERC-6909 claim on the PoolManager
    ///         held by the respective adapter admin.
    /// @dev Either adapter admin may call. Non-permissioned currencies (no verified adapter) credit the caller instead,
    ///      so single-PA pools route both legs to the sole admin. Claims are redeemable via `withdrawClaim`.
    /// @param tokenId The id of the position to seize
    function seize(uint256 tokenId) external isNotLocked {
        (PoolKey memory poolKey,) = getPoolAndPositionInfo(tokenId);
        address admin0 = _getOwner(poolKey.currency0);
        address admin1 = _getOwner(poolKey.currency1);
        if (msg.sender != admin0 && msg.sender != admin1) revert Unauthorized();

        address recipient0 = admin0 == address(0) ? msg.sender : admin0;
        address recipient1 = admin1 == address(0) ? msg.sender : admin1;

        // Pre-approve so the inner BURN_POSITION action passes `onlyIfApproved`.
        getApproved[tokenId] = msg.sender;

        emit PositionSeized(tokenId, ownerOf(tokenId), msg.sender, recipient0, recipient1);

        bytes memory actions =
            abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.MINT_6909), uint8(Actions.MINT_6909));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(tokenId, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(poolKey.currency0, recipient0, ActionConstants.OPEN_DELTA);
        params[2] = abi.encode(poolKey.currency1, recipient1, ActionConstants.OPEN_DELTA);

        poolManager.unlock(abi.encode(actions, params));
    }

    /// @notice Burn an ERC-6909 claim held on the PoolManager and transfer the underlying currency to `to`.
    /// @dev Caller must hold the claim or have granted this contract operator/allowance on PoolManager's ERC-6909.
    ///      For permissioned currencies, `to` must clear the underlying token's issuer compliance on unwrap.
    /// @param currency The currency whose claim is being withdrawn
    /// @param amount   The amount of claim to burn (and underlying to transfer)
    /// @param to       The recipient of the underlying
    function withdrawClaim(Currency currency, uint256 amount, address to) external isNotLocked {
        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_6909), uint8(Actions.TAKE));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(currency, msg.sender, amount);
        params[1] = abi.encode(currency, to, amount);
        poolManager.unlock(abi.encode(actions, params));
    }

    /// @inheritdoc PositionManager
    /// @dev Unilateral admin transfer: either currency admin may move the NFT without co-admin cooperation.
    ///      No recipient allowlist gate — that would let one admin block the other. Use `seize` to unwind atomically.
    function transferFrom(address from, address to, uint256 id) public override onlyIfPoolManagerLocked {
        (PoolKey memory poolKey,) = getPoolAndPositionInfo(id);
        address admin0 = _getOwner(poolKey.currency0);
        address admin1 = _getOwner(poolKey.currency1);
        if (msg.sender != admin0 && msg.sender != admin1) {
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

    /// @dev Adds MINT_6909 / BURN_6909 to the action set so `seize` and `withdrawClaim` can convert
    ///      open deltas into persistent ERC-6909 claims and back.
    function _handleAction(uint256 action, bytes calldata params) internal override {
        if (action == Actions.MINT_6909) {
            (Currency currency, address to, uint256 amount) = params.decodeCurrencyAddressAndUint256();
            if (amount == ActionConstants.OPEN_DELTA) amount = _getFullCredit(currency);
            poolManager.mint(to, currency.toId(), amount);
            return;
        }
        if (action == Actions.BURN_6909) {
            (Currency currency, address from, uint256 amount) = params.decodeCurrencyAddressAndUint256();
            poolManager.burn(from, currency.toId(), amount);
            return;
        }
        super._handleAction(action, params);
    }
}
