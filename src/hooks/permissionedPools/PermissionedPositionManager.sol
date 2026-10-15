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

    /// @notice Gas forwarded to each real-asset delivery attempt in `_tryDeliverAsset`.
    ///         Caps how much a malicious recipient can burn per attempt.
    uint256 public immutable DELIVERY_GAS_LIMIT;

    event CurrencyUnwound(
        uint256 indexed tokenId,
        Currency indexed currency,
        address indexed recipient,
        address caller,
        address lp,
        uint256 amount,
        bool asClaim
    );
    event ClaimWithdrawn(Currency indexed currency, address indexed from, address indexed to, uint256 amount);

    error InvalidHook();
    error TransferDisabled();
    error NoVerifiedAdapter();
    error NonContractCurrency();

    /// @dev as this contract must know the hooks address in advance, it must be passed in as a constructor argument
    constructor(
        IPoolManager _poolManager,
        IAllowanceTransfer _permit2,
        uint256 _unsubscribeGasLimit,
        IPositionDescriptor _tokenDescriptor,
        IWETH9 _weth9,
        IPermissionsAdapterFactory _permissionsAdapterFactory,
        uint256 _deliveryGasLimit
    ) PositionManager(_poolManager, _permit2, _unsubscribeGasLimit, _tokenDescriptor, _weth9) {
        PERMISSIONS_ADAPTER_FACTORY = _permissionsAdapterFactory;
        DELIVERY_GAS_LIMIT = _deliveryGasLimit;
        /// @dev The EIP712 domain separator still uses "Uniswap v4 Positions NFT" as the name
        name = "Uniswap v4 Permissioned Positions NFT";
        symbol = "UNI-V4-PERM-POSM";
    }

    /// @notice Force-exit the LP from a position. Burns the NFT, unwinds liquidity, and delivers each currency.
    /// @dev Either PA admin may call. First burns the position and settles both currencies as ERC-6909 claims to
    ///      this contract; minting a claim moves no token, so no LP-controlled code runs and this step cannot be
    ///      bricked. Then delivers each claim as the real asset to the LP, falling back to the admin, each in its
    ///      own isolated unlock capped at `DELIVERY_GAS_LIMIT`; a recipient that reverts, strands a delta, or burns
    ///      its capped gas only fails its own delivery, and the LP (or admin) is handed the 6909 claim instead
    ///      (see `_deliverCurrency`). Emits one `CurrencyUnwound` event per leg.
    /// @param tokenId The position to unwind
    /// @param amount0Min Minimum currency0 the burn must return; 0 disables the check
    /// @param amount1Min Minimum currency1 the burn must return; 0 disables the check
    /// @param hookData Forwarded to the pool's hook on removal, for hook extensions that require it
    /// @dev Non-zero bounds revert the burn instead of executing it below them.
    /// @dev Unsubscribes before burning, so the subscriber gets notifyUnsubscribe but not notifyBurn.
    function unwindPosition(uint256 tokenId, uint128 amount0Min, uint128 amount1Min, bytes calldata hookData)
        external
        isNotLocked
    {
        (PoolKey memory poolKey,) = getPoolAndPositionInfo(tokenId);
        address admin0 = _getOwner(poolKey.currency0);
        address admin1 = _getOwner(poolKey.currency1);
        if (msg.sender != admin0 && msg.sender != admin1) revert Unauthorized();

        address lp = ownerOf(tokenId);

        // Unsubscribe with the PoolManager locked so notifyUnsubscribe can't strand a delta and brick the unlock.
        if (positionInfo[tokenId].hasSubscriber()) {
            _unsubscribe(tokenId);
            // The locked callback can still re-attach via subscribe; clear it so a reverting notifyBurn can't brick the burn.
            // Its notifyUnsubscribe is deliberately not called (attacker-chosen), but emit Unsubscription so indexers stay balanced.
            if (positionInfo[tokenId].hasSubscriber()) {
                address reattached = address(subscriber[tokenId]);
                delete subscriber[tokenId];
                _setUnsubscribed(tokenId);
                emit Unsubscription(tokenId, reattached);
            }
        }

        // Approve so BURN_POSITION passes onlyIfApproved.
        // ERC-721 _burn clears getApproved as part of its teardown, so the approval is self-cleaning.
        getApproved[tokenId] = msg.sender;

        // Burn the position; settle both currencies as 6909 claims to this contract.
        bytes memory actions =
            abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.MINT_6909), uint8(Actions.MINT_6909));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(tokenId, amount0Min, amount1Min, hookData);
        params[1] = abi.encode(poolKey.currency0);
        params[2] = abi.encode(poolKey.currency1);
        poolManager.unlock(abi.encode(actions, params));

        // Reads the full 6909 balance, not a burn delta: the burn output plus any stray MINT_6909 claims
        // parked in this contract.
        uint256 amount0 = poolManager.balanceOf(address(this), poolKey.currency0.toId());
        uint256 amount1 = poolManager.balanceOf(address(this), poolKey.currency1.toId());

        // Deliver the real asset to the LP, then the admin; on any grief, hand over the 6909 claim instead.
        _deliverCurrency(poolKey.currency0, lp, tokenId, amount0);
        _deliverCurrency(poolKey.currency1, lp, tokenId, amount1);
    }

    /// @notice Burn an ERC-6909 claim on the PoolManager and transfer the underlying currency to `to`.
    /// @dev Caller must hold the claim or have called PoolManager.setOperator(permPosm, true). For permissioned
    ///      currencies, `to` must clear the underlying token's issuer compliance on unwrap. `to` follows the
    ///      standard `Actions.TAKE` recipient sentinels: `address(1)` remaps to the caller, `address(2)` to this
    ///      contract. Sentinels are resolved before both the underlying delivery and the `ClaimWithdrawn` event.
    /// @param currency The currency whose 6909 claim is being burned
    /// @param amount The amount of claim to burn (and underlying to deliver)
    /// @param to The recipient of the underlying currency
    function withdrawClaim(Currency currency, uint256 amount, address to) external isNotLocked {
        address resolvedTo = _mapRecipient(to);
        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_6909), uint8(Actions.TAKE));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(currency, msg.sender, amount);
        params[1] = abi.encode(currency, resolvedTo, amount);
        poolManager.unlock(abi.encode(actions, params));

        emit ClaimWithdrawn(currency, msg.sender, resolvedTo, amount);
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
    ///      Also rejects pools where neither side is a verified permissions adapter — those positions provide no
    ///      permissioning value over the base PositionManager and would otherwise be permanently non-transferable
    ///      (see `transferFrom`), so the manager refuses to mint them.
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
        // Validate each currency; require at least one to be a verified permissions adapter.
        bool verified0 = _validateLiquidityCurrency(poolKey.currency0, poolKey.hooks, owner);
        bool verified1 = _validateLiquidityCurrency(poolKey.currency1, poolKey.hooks, owner);
        if (!verified0 && !verified1) revert NoVerifiedAdapter();
        super._mint(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, hookData);
    }

    /// @dev Re-validate the hook allowlist on every liquidity increase so that a revoked hook cannot
    ///      continue to accept new inflows on existing positions. Also re-check that the position owner
    ///      still clears `LIQUIDITY_ALLOWED` for each permissioned currency. Decrease and burn paths are
    ///      intentionally left unchecked so that holders can always exit positions even after their
    ///      permissions or the hook have been revoked.
    function _increase(
        uint256 tokenId,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        bytes calldata hookData
    ) internal override {
        (PoolKey memory poolKey,) = getPoolAndPositionInfo(tokenId);
        address owner = ownerOf(tokenId);
        _validateLiquidityCurrency(poolKey.currency0, poolKey.hooks, owner);
        _validateLiquidityCurrency(poolKey.currency1, poolKey.hooks, owner);
        super._increase(tokenId, liquidity, amount0Max, amount1Max, hookData);
    }

    /// @dev See `_increase` — same rationale for the from-deltas variant.
    function _increaseFromDeltas(uint256 tokenId, uint128 amount0Max, uint128 amount1Max, bytes calldata hookData)
        internal
        override
    {
        (PoolKey memory poolKey,) = getPoolAndPositionInfo(tokenId);
        address owner = ownerOf(tokenId);
        _validateLiquidityCurrency(poolKey.currency0, poolKey.hooks, owner);
        _validateLiquidityCurrency(poolKey.currency1, poolKey.hooks, owner);
        super._increaseFromDeltas(tokenId, amount0Max, amount1Max, hookData);
    }

    /// @notice Validate `currency` for a liquidity-adding action and report whether it is a verified adapter.
    /// @dev Ordinary tokens pass. A factory-created adapter must be verified — otherwise it would be treated as
    ///      ordinary here, skip its hook/`LIQUIDITY_ALLOWED` checks, and be activated later via verification. A
    ///      verified adapter must allow `hooks` and clear the owner's `LIQUIDITY_ALLOWED`.
    function _validateLiquidityCurrency(Currency currency, IHooks hooks, address owner)
        internal
        view
        returns (bool isVerifiedAdapter)
    {
        address currencyAddress = Currency.unwrap(currency);
        if (_verifiedPermissionedTokenOf(currency) == address(0)) {
            if (PERMISSIONS_ADAPTER_FACTORY.permissionsAdapterOf(currencyAddress) != address(0)) {
                revert NoVerifiedAdapter();
            }
            // a non-adapter currency must be a real contract (native ETH excepted)
            if (currencyAddress != address(0) && currencyAddress.code.length == 0) revert NonContractCurrency();
            return false;
        }
        IPermissionsAdapter adapter = IPermissionsAdapter(currencyAddress);
        if (!adapter.allowedHooks(hooks)) revert InvalidHook();
        if (!adapter.isAllowed(owner, PermissionFlags.LIQUIDITY_ALLOWED)) revert Unauthorized();
        return true;
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
        // Check liquidity permission for the actual user
        if (!permissionsAdapter.isAllowed(msgSender(), PermissionFlags.LIQUIDITY_ALLOWED)) {
            revert Unauthorized();
        }
        if (payer == address(this)) {
            Currency.wrap(permissionedToken).transfer(address(permissionsAdapter), amount);
        } else {
            permit2.transferFrom(payer, address(permissionsAdapter), uint160(amount), permissionedToken);
        }
        permissionsAdapter.wrapToPoolManager(amount);
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

    /// @dev When a TAKE is performed with the adapter currency to this contract, the adapter's
    /// _update hook unwraps the adapter tokens, so this contract ends up holding the underlying
    /// permissioned token — not the adapter token. Sweep the underlying to avoid leaving
    /// tokens behind that a later caller could claim.
    function _sweep(Currency currency, address to) internal override {
        address permissionedToken = _verifiedPermissionedTokenOf(currency);
        if (permissionedToken == address(0)) {
            super._sweep(currency, to);
            return;
        }
        Currency underlying = Currency.wrap(permissionedToken);
        uint256 balance = underlying.balanceOfSelf();
        if (balance > 0) underlying.transfer(to, balance);
    }

    function _getOwner(Currency currency) internal view returns (address) {
        address permissionsAdapter = Currency.unwrap(currency);
        address permissionedToken = _verifiedPermissionedTokenOf(currency);
        if (permissionedToken == address(0)) return address(0);
        return IPermissionsAdapter(permissionsAdapter).owner();
    }

    /// @dev Handles the two unwind actions dispatched by `unwindPosition` (MINT_6909 and UNWIND_WITH_FALLBACK),
    ///      plus the BURN_6909 primitive used by `withdrawClaim`. All other actions fall through to the base
    ///      PositionManager dispatcher.
    function _handleAction(uint256 action, bytes calldata params) internal override {
        if (action == Actions.MINT_6909) {
            // Settle this contract's full positive delta for `currency` as a 6909 claim to itself.
            Currency currency = params.decodeCurrency();
            poolManager.mint(address(this), currency.toId(), _getFullCredit(currency));
            return;
        }
        if (action == Actions.UNWIND_WITH_FALLBACK) {
            // Burn this contract's claim for `currency` and take the real asset to `to`.
            (Currency currency, address to, uint256 amount) = params.decodeCurrencyAddressAndUint256();
            poolManager.burn(address(this), currency.toId(), amount);
            poolManager.take(currency, to, amount);
            return;
        }
        if (action == Actions.BURN_6909) {
            (Currency currency, address from, uint256 amount) = params.decodeCurrencyAddressAndUint256();
            // validate claim owner is the action executor before burning
            if (from != msgSender()) revert Unauthorized();
            poolManager.burn(from, currency.toId(), amount);
            return;
        }
        super._handleAction(action, params);
    }

    /// @notice Deliver `amount` of `currency` (held as a 6909 claim) to the LP, then the admin, else hand over the
    ///         claim. Each attempt is an isolated unlock capped at `DELIVERY_GAS_LIMIT`, so a reverting or gas-burning
    ///         recipient only fails its own leg. Emits one `CurrencyUnwound` per leg.
    function _deliverCurrency(Currency currency, address lp, uint256 tokenId, uint256 amount) internal {
        if (amount == 0) return;

        // Real asset to the LP.
        if (_tryDeliverAsset(currency, lp, amount)) {
            emit CurrencyUnwound(tokenId, currency, lp, msg.sender, lp, amount, false);
            return;
        }
        // Then the admin (permissioned currencies only; renounce is disabled, so a permissioned admin is never zero).
        address admin = _getOwner(currency);
        if (admin != address(0) && _tryDeliverAsset(currency, admin, amount)) {
            emit CurrencyUnwound(tokenId, currency, admin, msg.sender, lp, amount, false);
            return;
        }
        // Both rejected: hand over the 6909 claim (no token code runs). Admin for a permissioned currency (the LP
        // is non-compliant), else the LP.
        address claimTo = admin == address(0) ? lp : admin;
        poolManager.transfer(claimTo, currency.toId(), amount);
        emit CurrencyUnwound(tokenId, currency, claimTo, msg.sender, lp, amount, true);
    }

    /// @notice Attempt to deliver the real asset for `amount` of `currency` to `to` in an isolated unlock (burn
    ///         this contract's claim, take to `to`), forwarding at most `DELIVERY_GAS_LIMIT` gas. Returns false if
    ///         `to` reverts, strands a delta, or exhausts the capped gas, in which case nothing was delivered and
    ///         this contract still holds the claim.
    function _tryDeliverAsset(Currency currency, address to, uint256 amount) internal returns (bool) {
        bytes memory actions = abi.encodePacked(uint8(Actions.UNWIND_WITH_FALLBACK));
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(currency, to, amount);
        try poolManager.unlock{gas: DELIVERY_GAS_LIMIT}(abi.encode(actions, params)) {
            return true;
        } catch {
            return false;
        }
    }
}
