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
///         `onBehalf`, constrains every fund recipient to the manager or owner, routes every call to
///         the adapter's declared `lendingProtocol()`, and performs a regular call (never a
///         delegatecall). Adapter trust is established by the manager (which only routes allowlisted
///         adapters) or by the owner choosing the adapter for their own funds.
/// @custom:security-contact security@uniswap.org
contract MarginAccount is IMarginAccount {
    using CustomRevert for bytes4;
    using SafeERC20 for IERC20;

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
        _setApproval(market.collateral, target, amount);
        _execCall(target, value, callData);
        _setApproval(market.collateral, target, 0);
        emit CollateralSupplied(msg.sender, address(adapter), market.collateral, amount);
        return amount;
    }

    /// @inheritdoc IMarginAccount
    /// @dev Forwards the withdrawn collateral to the validated receiver, mirroring `borrow`. Lending
    ///      protocols differ on whether `withdraw` exposes a recipient: some deliver straight to `to`
    ///      (the account's measured delta is then zero and nothing is forwarded), others deliver to the
    ///      caller (the account), which forwards the measured delta here. Either way the recipient stays
    ///      under the account's control. `withdrawn` is measured as the account's collateral-token
    ///      balance increase across the call, so it is zero when the protocol delivered directly to `to`.
    function withdrawCollateral(ILendingAdapter adapter, Market calldata market, uint256 amount, address to)
        external
        returns (uint256 withdrawn)
    {
        (address ownerAddr, address managerAddr) = _authCaller();
        _requireReceiver(to, ownerAddr, managerAddr);
        uint256 balanceBefore = market.collateral.balanceOfSelf();
        (address target, uint256 value, bytes memory callData) =
            adapter.encodeWithdrawCollateral(address(this), market, amount, to);
        _execCall(target, value, callData);
        withdrawn = market.collateral.balanceOfSelf() - balanceBefore;
        if (withdrawn != 0) market.collateral.transfer(to, withdrawn);
        emit CollateralWithdrawn(msg.sender, address(adapter), market.collateral, withdrawn, to);
    }

    /// @inheritdoc IMarginAccount
    /// @dev Borrows to the account, then forwards the proceeds to the validated receiver. The
    ///      borrowed asset is always delivered to the account because lending protocols differ on
    ///      whether `borrow` exposes a receiver; forwarding here keeps the recipient under the
    ///      account's control regardless. `borrowed` is measured as the debt token balance increase
    ///      (mirroring `repay`), which is accurate across protocols rather than trusting `amount`.
    function borrow(ILendingAdapter adapter, Market calldata market, uint256 amount, address to)
        external
        returns (uint256 borrowed)
    {
        (address ownerAddr, address managerAddr) = _authCaller();
        _requireReceiver(to, ownerAddr, managerAddr);
        uint256 balanceBefore = market.debt.balanceOfSelf();
        (address target, uint256 value, bytes memory callData) = adapter.encodeBorrow(address(this), market, amount);
        _execCall(target, value, callData);
        borrowed = market.debt.balanceOfSelf() - balanceBefore;
        market.debt.transfer(to, borrowed);
        emit Borrowed(msg.sender, address(adapter), market.debt, borrowed, to);
    }

    /// @inheritdoc IMarginAccount
    /// @dev Approves the lending protocol for `amount` (or the full balance for `type(uint256).max`)
    ///      before the call and resets the allowance to zero afterward. `repaid` is measured as the
    ///      debt token balance decrease, which is accurate for both partial and full-share repays.
    function repay(ILendingAdapter adapter, Market calldata market, uint256 amount) external returns (uint256 repaid) {
        _authCaller();
        (address target, uint256 value, bytes memory callData) = adapter.encodeRepay(address(this), market, amount);
        uint256 balanceBefore = market.debt.balanceOfSelf();
        uint256 approveAmount = amount == type(uint256).max ? balanceBefore : amount;
        _setApproval(market.debt, target, approveAmount);
        _execCall(target, value, callData);
        _setApproval(market.debt, target, 0);
        repaid = balanceBefore - market.debt.balanceOfSelf();
        emit Repaid(msg.sender, address(adapter), market.debt, repaid);
    }

    /// @inheritdoc IMarginAccount
    function sweep(Currency currency, uint256 amount, address to) external {
        (address ownerAddr, address managerAddr) = _authCaller();
        _requireReceiver(to, ownerAddr, managerAddr);
        currency.transfer(to, amount);
        emit Swept(msg.sender, currency, amount, to);
    }

    /// @inheritdoc IMarginAccount
    function execute(ILendingAdapter adapter, bytes calldata adapterCall)
        external
        payable
        returns (bytes memory result)
    {
        (address ownerAddr,) = _ownerAndManager();
        if (msg.sender != ownerAddr) NotAuthorized.selector.revertWith();
        address target = adapter.lendingProtocol();
        result = _execCall(target, msg.value, adapterCall);
        emit Executed(msg.sender, address(adapter), target);
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

    /// @notice Approves the target for `amount`.
    /// @param currency The currency to approve.
    /// @param target The target to approve.
    /// @param amount The amount to approve.
    function _setApproval(Currency currency, address target, uint256 amount) internal {
        IERC20(Currency.unwrap(currency)).forceApprove(target, amount);
    }

    /// @notice Forwards the adapter-encoded call to `target` as this account with a regular call
    ///         (never a delegatecall), reverting on failure via `Address.functionCallWithValue`.
    /// @param target The call target (the adapter's `lendingProtocol()`).
    /// @param value The call value; forwarded from the adapter's encoding (zero for the standard
    ///        non-payable lending calls, and the account holds no native balance to forward).
    /// @param callData The calldata to forward.
    /// @return The raw bytes returned by the lending protocol call.
    function _execCall(address target, uint256 value, bytes memory callData) internal returns (bytes memory) {
        return Address.functionCallWithValue(target, callData, value);
    }

    /// @notice Receives native currency into the account. Used for advanced adapter calls that require native currency.
    function receive() external payable {}
}
