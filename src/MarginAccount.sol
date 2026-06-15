// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "openzeppelin-contracts/contracts/utils/Address.sol";
import {LibClone} from "solady/utils/LibClone.sol";

import {IMarginAccount} from "./interfaces/IMarginAccount.sol";
import {ILendingAdapter} from "./interfaces/ILendingAdapter.sol";
import {Market} from "./types/Market.sol";

/// @title MarginAccount
/// @author Uniswap Labs
/// @notice The per-user position container, deployed as a Solady clone-with-immutable-args. The
///         account is the borrower and supplier in the lending protocol, so it acts as itself and
///         needs no delegated authorization. The owner and manager are baked into the clone
///         bytecode (read via `LibClone.argsOnClone`), so there is no initializer to front-run and
///         no transfer path: ownership is soulbound.
///
///         The account owns the authority-bearing fields. It always passes itself as the lending
///         `onBehalf`, constrains every fund recipient to the manager or owner, asserts each
///         adapter-encoded call targets the adapter's lending protocol, and performs a regular call
///         (never a delegatecall). Adapter trust is established by the manager (which only routes
///         allowlisted adapters) or by the owner choosing the adapter for their own funds; the
///         target check here is defense in depth.
/// @custom:security-contact security@uniswap.org
contract MarginAccount is IMarginAccount {
    using CustomRevert for bytes4;
    using SafeERC20 for IERC20;

    /// @dev Thrown when an adapter-encoded call targets an address other than the adapter's
    ///      declared `lendingProtocol()`. Prevents a rogue adapter from redirecting the account's
    ///      call to an arbitrary contract.
    error TargetNotLendingProtocol();

    /// @dev Thrown when an adapter-encoded call carries a non-zero `value`. Lending protocol calls
    ///      are expected to be non-payable; a non-zero value would indicate a misconfigured adapter.
    error UnexpectedCallValue();

    /// @inheritdoc IMarginAccount
    function owner() public view returns (address ownerAddr) {
        (ownerAddr,) = _ownerAndManager();
    }

    /// @inheritdoc IMarginAccount
    function manager() public view returns (address managerAddr) {
        (, managerAddr) = _ownerAndManager();
    }

    /// @inheritdoc IMarginAccount
    /// @dev Approves the lending protocol for `amount` before the call and resets the allowance to
    ///      zero afterward, so no residual approval lingers on the lending contract.
    function supplyCollateral(ILendingAdapter adapter, Market calldata market, uint256 amount)
        external
        returns (uint256)
    {
        _authCaller();
        (address target, uint256 value, bytes memory callData) =
            adapter.encodeSupplyCollateral(address(this), market, amount);
        IERC20 collateral = IERC20(Currency.unwrap(market.collateral));
        collateral.forceApprove(target, amount);
        _execCall(adapter, target, value, callData);
        collateral.forceApprove(target, 0);
        return amount;
    }

    /// @inheritdoc IMarginAccount
    function withdrawCollateral(ILendingAdapter adapter, Market calldata market, uint256 amount, address to)
        external
        returns (uint256)
    {
        (address ownerAddr, address managerAddr) = _authCaller();
        _requireReceiver(to, ownerAddr, managerAddr);
        (address target, uint256 value, bytes memory callData) =
            adapter.encodeWithdrawCollateral(address(this), market, amount, to);
        _execCall(adapter, target, value, callData);
        return amount;
    }

    /// @inheritdoc IMarginAccount
    function borrow(ILendingAdapter adapter, Market calldata market, uint256 amount, address to)
        external
        returns (uint256)
    {
        (address ownerAddr, address managerAddr) = _authCaller();
        _requireReceiver(to, ownerAddr, managerAddr);
        (address target, uint256 value, bytes memory callData) =
            adapter.encodeBorrow(address(this), market, amount, to);
        _execCall(adapter, target, value, callData);
        return amount;
    }

    /// @inheritdoc IMarginAccount
    /// @dev Approves the lending protocol for `amount` (or the full balance for `type(uint256).max`)
    ///      before the call and resets the allowance to zero afterward. `repaid` is measured as the
    ///      debt token balance decrease, which is accurate for both partial and full-share repays.
    function repay(ILendingAdapter adapter, Market calldata market, uint256 amount)
        external
        returns (uint256 repaid)
    {
        _authCaller();
        (address target, uint256 value, bytes memory callData) =
            adapter.encodeRepay(address(this), market, amount);
        IERC20 debt = IERC20(Currency.unwrap(market.debt));
        uint256 balanceBefore = debt.balanceOf(address(this));
        uint256 approveAmount = amount == type(uint256).max ? balanceBefore : amount;
        debt.forceApprove(target, approveAmount);
        _execCall(adapter, target, value, callData);
        debt.forceApprove(target, 0);
        repaid = balanceBefore - debt.balanceOf(address(this));
    }

    /// @inheritdoc IMarginAccount
    function sweep(Currency currency, uint256 amount, address to) external {
        (address ownerAddr, address managerAddr) = _authCaller();
        _requireReceiver(to, ownerAddr, managerAddr);
        IERC20(Currency.unwrap(currency)).safeTransfer(to, amount);
    }

    /// @inheritdoc IMarginAccount
    /// @dev `market` is accepted for interface symmetry but is not inspected here; the call target
    ///      is constrained to `adapter.lendingProtocol()` by `Address.functionCall`, which also
    ///      reverts on failure.
    function execute(ILendingAdapter adapter, Market calldata, bytes calldata adapterCall)
        external
        returns (bytes memory)
    {
        (address ownerAddr,) = _ownerAndManager();
        if (msg.sender != ownerAddr) NotAuthorized.selector.revertWith();
        return Address.functionCall(adapter.lendingProtocol(), adapterCall);
    }

    /// @notice Reads the soulbound `(owner, manager)` from the clone's immutable args. During
    ///         execution, `address(this)` is the clone, so `LibClone.argsOnClone` reads the args
    ///         appended to that clone's bytecode.
    /// @return ownerAddr The clone's baked-in owner.
    /// @return managerAddr The clone's baked-in manager.
    function _ownerAndManager() internal view returns (address ownerAddr, address managerAddr) {
        (ownerAddr, managerAddr) = abi.decode(LibClone.argsOnClone(address(this)), (address, address));
    }

    /// @notice Reverts unless `msg.sender` is the manager or owner. Returns both addresses for
    ///         reuse by callers that need them for further checks (e.g. `_requireReceiver`).
    /// @return ownerAddr The clone's baked-in owner.
    /// @return managerAddr The clone's baked-in manager.
    function _authCaller() internal view returns (address ownerAddr, address managerAddr) {
        (ownerAddr, managerAddr) = _ownerAndManager();
        if (msg.sender != managerAddr && msg.sender != ownerAddr) NotAuthorized.selector.revertWith();
    }

    /// @notice Reverts unless `to` is the manager or owner. The account owns the recipient field;
    ///         it is never taken from adapter-encoded bytes, preventing fund redirection.
    /// @param to The proposed recipient address.
    /// @param ownerAddr The clone's baked-in owner.
    /// @param managerAddr The clone's baked-in manager.
    function _requireReceiver(address to, address ownerAddr, address managerAddr) internal pure {
        if (to != managerAddr && to != ownerAddr) ReceiverNotAllowed.selector.revertWith(to);
    }

    /// @notice Asserts the adapter-encoded call targets the adapter's lending protocol and carries
    ///         no value, then performs a regular call (never a delegatecall). Reverts on failure via
    ///         `Address.functionCall`.
    /// @dev The target and value checks are defense in depth: the manager only routes allowlisted
    ///      adapters, and the owner deliberately chooses the adapter for their own funds.
    /// @param adapter The adapter whose `lendingProtocol()` is the permitted target.
    /// @param target The encoded call target; must equal `adapter.lendingProtocol()`.
    /// @param value The encoded call value; must be zero.
    /// @param callData The calldata to forward.
    /// @return The raw bytes returned by the lending protocol call.
    function _execCall(ILendingAdapter adapter, address target, uint256 value, bytes memory callData)
        internal
        returns (bytes memory)
    {
        if (target != adapter.lendingProtocol()) TargetNotLendingProtocol.selector.revertWith();
        if (value != 0) UnexpectedCallValue.selector.revertWith();
        return Address.functionCall(target, callData);
    }
}
