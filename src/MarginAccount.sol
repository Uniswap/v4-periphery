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
import {Call} from "./types/Call.sol";
import {Market} from "./types/Market.sol";

/// @title MarginAccount
/// @author Uniswap Labs
/// @notice The per-user position container, deployed as a Solady clone-with-immutable-args. The
///         account is the borrower and supplier in the lending protocol, so it acts as itself and
///         needs no delegated authorization. The owner and manager are baked into the clone
///         bytecode (read via `LibClone.argsOnClone`), so there is no initializer to front-run and
///         no transfer path: ownership is soulbound.
///
///         The account enforces what it can see: it passes its own address as the `account` argument
///         to every encoder, validates the `to` it is handed against the manager and owner, performs
///         every call against the adapter's `lendingProtocol()`, and uses a regular call (never a
///         delegatecall). It does NOT decode the calldata the adapter returns, so the `value` and any
///         recipient baked into those bytes are the adapter's word. Adapter honesty is an assumption
///         this contract does not verify.
///
///         The adapter is caller-chosen on every path; there is no allowlist. That is safe because the
///         manager derives the account from the authenticated caller, so a hostile adapter reaches
///         only the caller's own account, and the owner-only `execute` already grants that same power
///         outright. The caller, or the app that built the transaction, vets the adapter exactly as it
///         vets the market it names.
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
    /// @dev Approves the lending protocol for `amount` around the adapter's sequence (the supply, plus
    ///      the explicit collateral enable on venues that need one) and resets the allowance to zero
    ///      afterward, so no residual approval lingers on the lending contract.
    function supplyCollateral(ILendingAdapter adapter, Market calldata market, uint256 amount)
        external
        returns (uint256)
    {
        _authCaller();
        address target = adapter.lendingProtocol();
        Call[] memory calls = adapter.encodeSupplyCollateral(address(this), market, amount);
        _setApproval(market.collateral, target, amount);
        _execCalls(target, calls);
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
        _execCalls(adapter.lendingProtocol(), adapter.encodeWithdrawCollateral(address(this), market, amount, to));
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
        _execCalls(adapter.lendingProtocol(), adapter.encodeBorrow(address(this), market, amount));
        borrowed = market.debt.balanceOfSelf() - balanceBefore;
        market.debt.transfer(to, borrowed);
        emit Borrowed(msg.sender, address(adapter), market.debt, borrowed, to);
    }

    /// @inheritdoc IMarginAccount
    /// @dev Approves the lending protocol for `amount` (or the full balance for `type(uint256).max`)
    ///      around the adapter's sequence and resets the allowance to zero afterward. `repaid` is
    ///      measured as the debt token balance decrease, which is accurate for both partial and
    ///      full-share repays.
    function repay(ILendingAdapter adapter, Market calldata market, uint256 amount) external returns (uint256 repaid) {
        _authCaller();
        Call[] memory calls = adapter.encodeRepay(address(this), market, amount);
        // No debt to repay: the adapter encoded no calls. Skip the step and report zero so a "repay
        // then withdraw" exit plan runs cleanly against a position with no outstanding debt.
        if (calls.length == 0) {
            emit Repaid(msg.sender, address(adapter), market.debt, 0);
            return 0;
        }
        address target = adapter.lendingProtocol();
        uint256 balanceBefore = market.debt.balanceOfSelf();
        uint256 approveAmount = amount == type(uint256).max ? balanceBefore : amount;
        _setApproval(market.debt, target, approveAmount);
        _execCalls(target, calls);
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

    /// @notice Reverts unless `to` is the manager or owner. This bounds the recipient the CALLER
    ///         may name.
    /// @param to The proposed recipient address.
    /// @param ownerAddr The clone's baked-in owner.
    /// @param managerAddr The clone's baked-in manager.
    function _requireReceiver(address to, address ownerAddr, address managerAddr) internal view {
        if (to != managerAddr && to != ownerAddr) ReceiverNotAllowed.selector.revertWith(to);
    }

    /// @notice Approves the target for `amount`.
    /// @param currency The currency to approve.
    /// @param target The target to approve.
    /// @param amount The amount to approve.
    function _setApproval(Currency currency, address target, uint256 amount) internal {
        IERC20(Currency.unwrap(currency)).forceApprove(target, amount);
    }

    /// @notice Performs an adapter-encoded sequence against `target`, in order, stopping at the first
    ///         failure (each call reverts on failure via `_execCall`).
    /// @param target The adapter's `lendingProtocol()`.
    /// @param calls The sequence to perform.
    function _execCalls(address target, Call[] memory calls) internal {
        for (uint256 i = 0; i < calls.length; i++) {
            _execCall(target, calls[i].value, calls[i].data);
        }
    }

    /// @notice Forwards one call to `target` as this account with a regular call (never a
    ///         delegatecall), reverting on failure via `Address.functionCallWithValue`.
    /// @param target The adapter's `lendingProtocol()`.
    /// @param value The call value, taken from the adapter's encoding. Every in-tree adapter
    ///        returns zero today because the supported lending protocols don't support native
    ///        currency. However, future adapters may support native currency, so the account
    ///        can hold native currency (see `receive`), and a non-zero value would spend it.
    /// @param callData The calldata to forward.
    /// @return The raw bytes returned by the lending protocol call.
    function _execCall(address target, uint256 value, bytes memory callData) internal returns (bytes memory) {
        return Address.functionCallWithValue(target, callData, value);
    }

    /// @notice Receives native currency into the account. Used for advanced adapter calls that require native currency.
    receive() external payable {}
}
