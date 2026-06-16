// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ILendingAdapter} from "./ILendingAdapter.sol";
import {Market} from "../types/Market.sol";

/// @title IMarginAccount
/// @author Uniswap Labs
/// @notice Per-user position container. The account itself is the borrower and supplier in the
///         lending protocol, so it self-acts and never needs delegated authorization. Ownership is
///         soulbound: owner and manager are baked into the clone bytecode as immutable args, so
///         there is no initializer and no transfer path. Every privileged primitive is callable
///         only by the manager (the margin router) or the owner.
interface IMarginAccount {
    /// @dev Thrown when a privileged primitive is called by neither the manager nor the owner.
    error NotAuthorized();

    /// @dev Thrown when a withdraw, borrow, or sweep recipient is neither the manager nor the owner.
    ///      The account enforces the recipient constraint itself, so adapter-encoded bytes cannot
    ///      redirect funds to an arbitrary address.
    /// @param to The disallowed recipient address that was supplied.
    error ReceiverNotAllowed(address to);

    /// @notice The account owner. Baked into the clone bytecode at deployment; cannot be changed.
    /// @return The owner address.
    function owner() external view returns (address);

    /// @notice The trusted manager (the margin router). Baked into the clone bytecode at deployment;
    ///         cannot be changed.
    /// @return The manager address.
    function manager() external view returns (address);

    /// @notice Supply `amount` of `market.collateral` to the lending protocol as this account.
    ///         Callable by the manager or owner.
    /// @param adapter The lending adapter that encodes the supply call and identifies the protocol.
    /// @param market The (collateral, debt) pair identifying the target lending market.
    /// @param amount The amount of collateral to supply, in the collateral token's native decimals.
    /// @return supplied The amount actually supplied (equal to `amount`).
    function supplyCollateral(ILendingAdapter adapter, Market calldata market, uint256 amount)
        external
        returns (uint256 supplied);

    /// @notice Withdraw `amount` of `market.collateral` to `to`, which must be the manager or owner.
    ///         Callable by the manager or owner.
    /// @param adapter The lending adapter that encodes the withdrawal call.
    /// @param market The (collateral, debt) pair identifying the target lending market.
    /// @param amount The amount of collateral to withdraw, in the collateral token's native decimals.
    /// @param to The recipient address; must be the manager or owner.
    /// @return withdrawn The collateral delivered to the account and forwarded to `to`, measured as the
    ///         account's collateral-token balance increase across the call. Zero when the lending
    ///         protocol delivers the withdrawal directly to `to`.
    function withdrawCollateral(ILendingAdapter adapter, Market calldata market, uint256 amount, address to)
        external
        returns (uint256 withdrawn);

    /// @notice Borrow `amount` of `market.debt` to `to`, which must be the manager or owner. The
    ///         account borrows to itself and forwards the proceeds to `to`. Callable by the manager
    ///         or owner.
    /// @param adapter The lending adapter that encodes the borrow call.
    /// @param market The (collateral, debt) pair identifying the target lending market.
    /// @param amount The amount to borrow, in the debt token's native decimals.
    /// @param to The recipient address; must be the manager or owner.
    /// @return borrowed The assets actually borrowed, measured as the account's debt-token balance
    ///         increase across the call.
    function borrow(ILendingAdapter adapter, Market calldata market, uint256 amount, address to)
        external
        returns (uint256 borrowed);

    /// @notice Repay `amount` of `market.debt`. Passing `type(uint256).max` repays all outstanding
    ///         debt by shares, avoiding interest dust left by asset-denominated rounding. Callable by
    ///         the manager or owner.
    /// @param adapter The lending adapter that encodes the repay call.
    /// @param market The (collateral, debt) pair identifying the target lending market.
    /// @param amount The amount to repay in the debt token's native decimals, or `type(uint256).max`
    ///        for a full share-based repay.
    /// @return repaid The assets actually repaid, measured as the account's debt-token balance
    ///         decrease after the call.
    function repay(ILendingAdapter adapter, Market calldata market, uint256 amount) external returns (uint256 repaid);

    /// @notice Transfer `amount` of `currency` out of the account to `to` (residual or realized
    ///         PnL). `to` must be the manager or owner. Callable by the manager or owner.
    /// @param currency The ERC-20 token to transfer out.
    /// @param amount The amount to transfer, in the token's native decimals.
    /// @param to The recipient address; must be the manager or owner.
    function sweep(Currency currency, uint256 amount, address to) external;

    /// @notice Owner-only escape hatch. Runs an adapter-encoded call against the adapter's lending
    ///         protocol as this account, so the owner can always close a position or recover funds
    ///         without involving the manager. The call target is constrained to the adapter's
    ///         `lendingProtocol()`.
    /// @dev Callable only by the owner (not the manager). The `market` parameter is accepted for
    ///      interface symmetry with other primitives but is unused by the implementation.
    /// @param adapter The lending adapter whose `lendingProtocol()` is the permitted call target.
    /// @param market The market context (accepted for symmetry; not validated by this function).
    /// @param adapterCall Raw calldata to forward to the lending protocol.
    /// @return result The raw bytes returned by the lending protocol call.
    function execute(ILendingAdapter adapter, Market calldata market, bytes calldata adapterCall)
        external
        returns (bytes memory result);
}
