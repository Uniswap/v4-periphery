// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ILendingAdapter} from "./ILendingAdapter.sol";
import {Market} from "../types/Market.sol";

/// @notice Per-user position container. The account itself is the borrower and supplier in the
///         lending protocol, so it self-acts and never needs delegated authorization. Ownership is
///         soulbound: owner and manager are baked into the clone bytecode as immutable args, so
///         there is no initializer and no transfer path. Every privileged primitive is callable
///         only by the manager (the margin router) or the owner.
interface IMarginAccount {
    /// @notice Thrown when a privileged primitive is called by neither the manager nor the owner.
    error NotAuthorized();
    /// @notice Thrown when a withdraw, borrow, or sweep recipient is neither the manager nor owner.
    error ReceiverNotAllowed(address to);

    /// @notice The account owner. Baked into the clone bytecode.
    function owner() external view returns (address);

    /// @notice The trusted manager (the margin router). Baked into the clone bytecode.
    function manager() external view returns (address);

    /// @notice Supply `amount` of `market.collateral` to the lending protocol as this account.
    function supplyCollateral(ILendingAdapter adapter, Market calldata market, uint256 amount)
        external
        returns (uint256 supplied);

    /// @notice Withdraw `amount` of `market.collateral` to `to`, which must be the manager or owner.
    function withdrawCollateral(ILendingAdapter adapter, Market calldata market, uint256 amount, address to)
        external
        returns (uint256 withdrawn);

    /// @notice Borrow `amount` of `market.debt` to `to`, which must be the manager or owner.
    function borrow(ILendingAdapter adapter, Market calldata market, uint256 amount, address to)
        external
        returns (uint256 borrowed);

    /// @notice Repay `amount` of `market.debt`. A value of type(uint256).max repays all. Returns the
    ///         assets actually repaid (measured as the account's debt-token balance decrease).
    function repay(ILendingAdapter adapter, Market calldata market, uint256 amount)
        external
        returns (uint256 repaid);

    /// @notice Transfer `amount` of `currency` out of the account to `to` (residual or realized
    ///         PnL). `to` must be the manager or owner.
    function sweep(Currency currency, uint256 amount, address to) external;

    /// @notice Owner-only escape hatch. Runs an adapter-encoded call against the adapter's lending
    ///         protocol as this account, so the owner can always close a position or recover funds
    ///         without involving the manager. Restricted to the owner; the call target is
    ///         constrained to the adapter's lendingProtocol().
    function execute(ILendingAdapter adapter, Market calldata market, bytes calldata adapterCall)
        external
        returns (bytes memory result);
}
