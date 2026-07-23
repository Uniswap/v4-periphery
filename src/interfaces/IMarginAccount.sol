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

    /// @notice Emitted when the account supplies collateral to the lending protocol. `caller` is
    ///         indexed so indexers can distinguish manager-driven activity from owner escape-hatch
    ///         activity (which the router's own events do not cover) without inspecting the tx.
    /// @param caller The `msg.sender` that drove the call (the manager or the owner).
    /// @param adapter The lending adapter used.
    /// @param collateral The collateral currency supplied.
    /// @param amount The amount supplied, in the collateral token's native decimals.
    event CollateralSupplied(
        address indexed caller, address indexed adapter, Currency indexed collateral, uint256 amount
    );

    /// @notice Emitted when the account withdraws collateral and forwards it to `to`.
    /// @param caller The `msg.sender` that drove the call (the manager or the owner).
    /// @param adapter The lending adapter used.
    /// @param collateral The collateral currency withdrawn.
    /// @param amount The amount forwarded to `to`, measured as the account's balance increase.
    /// @param to The recipient (the manager or the owner).
    event CollateralWithdrawn(
        address indexed caller, address indexed adapter, Currency indexed collateral, uint256 amount, address to
    );

    /// @notice Emitted when the account borrows debt and forwards it to `to`.
    /// @param caller The `msg.sender` that drove the call (the manager or the owner).
    /// @param adapter The lending adapter used.
    /// @param debt The debt currency borrowed.
    /// @param amount The amount forwarded to `to`, measured as the account's balance increase.
    /// @param to The recipient (the manager or the owner).
    event Borrowed(address indexed caller, address indexed adapter, Currency indexed debt, uint256 amount, address to);

    /// @notice Emitted when the account repays debt to the lending protocol.
    /// @param caller The `msg.sender` that drove the call (the manager or the owner).
    /// @param adapter The lending adapter used.
    /// @param debt The debt currency repaid.
    /// @param amount The amount repaid, measured as the account's balance decrease.
    event Repaid(address indexed caller, address indexed adapter, Currency indexed debt, uint256 amount);

    /// @notice Emitted when the account sweeps a token balance to `to`.
    /// @param caller The `msg.sender` that drove the call (the manager or the owner).
    /// @param currency The token swept.
    /// @param amount The amount transferred to `to`.
    /// @param to The recipient (the manager or the owner).
    event Swept(address indexed caller, Currency indexed currency, uint256 amount, address to);

    /// @notice Emitted when the owner runs the escape-hatch `execute` against the lending protocol.
    /// @param caller The owner that drove the call.
    /// @param adapter The lending adapter whose `lendingProtocol()` was called.
    /// @param target The call target (the adapter's lending protocol).
    event Executed(address indexed caller, address indexed adapter, address target);

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
    ///         without involving the manager. The call target is the adapter's `lendingProtocol()`.
    /// @dev Callable only by the owner (not the manager).
    /// @param adapter The lending adapter whose `lendingProtocol()` is the call target.
    /// @param adapterCall Raw calldata to forward to the lending protocol.
    /// @return result The raw bytes returned by the lending protocol call.
    function execute(ILendingAdapter adapter, bytes calldata adapterCall) external payable returns (bytes memory result);
}
