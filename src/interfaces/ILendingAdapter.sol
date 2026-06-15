// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Market} from "../types/Market.sol";
import {Ltv} from "../types/Ltv.sol";

/// @title ILendingAdapter
/// @author Uniswap Labs
/// @notice Lending-protocol-agnostic surface the margin router and account depend on. One singleton
///         instance per lending protocol; the specific market is selected by the `Market`
///         (collateral, debt) token pair passed to each call and resolved internally.
/// @dev The adapter is an ENCODER: each `encode*` returns the call the `MarginAccount` performs as
///      itself (`account == msg.sender == position owner`), so no delegated authorization is ever
///      required. Authority-bearing fields (`onBehalf` for every call, `receiver` for withdraw) are
///      owned and re-validated by the account; the account does NOT trust adapter-encoded bytes for
///      them. Borrowed funds are always delivered to the account, which forwards them to the
///      validated receiver, so `encodeBorrow` carries no receiver. Encode and read calls revert
///      `MarketNotSupported` (declared in `MarketRegistry`) for unrouted pairs, never a silent
///      default market.
interface ILendingAdapter {
    /// @notice The lending protocol singleton the account must call (the target of the account's
    ///         CALL). One address for every market this adapter routes to (e.g. Morpho Blue).
    /// @return The address of the underlying lending protocol singleton.
    function lendingProtocol() external view returns (address);

    /// @notice Whether the adapter can route `market` to a vetted protocol market.
    /// @param market The (collateral, debt) token pair to check.
    /// @return True if the pair has a registered market; false otherwise.
    function isSupportedMarket(Market calldata market) external view returns (bool);

    /// @notice Encode the call to supply `amount` of `market.collateral` with `onBehalf = account`.
    /// @param account The MarginAccount supplying collateral; used as the `onBehalf` argument.
    /// @param market The (collateral, debt) pair identifying the target lending market.
    /// @param amount The amount of collateral to supply, in the collateral token's native decimals.
    /// @return target The call target (always `lendingProtocol()`).
    /// @return value The call value. Always 0 for Morpho (non-payable); the account treats non-zero
    ///         as a bug.
    /// @return callData The calldata the account executes against `target`.
    function encodeSupplyCollateral(address account, Market calldata market, uint256 amount)
        external
        view
        returns (address target, uint256 value, bytes memory callData);

    /// @notice Encode the call to withdraw `amount` of `market.collateral` to `receiver`.
    /// @param account The MarginAccount whose collateral is being withdrawn; used as `onBehalf`.
    /// @param market The (collateral, debt) pair identifying the target lending market.
    /// @param amount The amount of collateral to withdraw, in the collateral token's native decimals.
    /// @param receiver The address that will receive the withdrawn collateral. The account enforces
    ///        that this is the manager or owner before executing.
    /// @return target The call target (always `lendingProtocol()`).
    /// @return value The call value. Always 0 for non-payable lending protocols.
    /// @return callData The calldata the account executes against `target`.
    function encodeWithdrawCollateral(address account, Market calldata market, uint256 amount, address receiver)
        external
        view
        returns (address target, uint256 value, bytes memory callData);

    /// @notice Encode the call to borrow `amount` of `market.debt` to the account itself.
    /// @dev The borrowed asset is delivered to the account, which forwards it to the manager or
    ///      owner receiver it validates. The receiver is therefore not an `encodeBorrow` concern.
    /// @param account The MarginAccount whose borrowing capacity is used; used as `onBehalf` and as
    ///        the borrow recipient so the account holds the funds before forwarding.
    /// @param market The (collateral, debt) pair identifying the target lending market.
    /// @param amount The amount of debt to borrow, in the debt token's native decimals.
    /// @return target The call target (always `lendingProtocol()`).
    /// @return value The call value. Always 0 for non-payable lending protocols.
    /// @return callData The calldata the account executes against `target`.
    function encodeBorrow(address account, Market calldata market, uint256 amount)
        external
        view
        returns (address target, uint256 value, bytes memory callData);

    /// @notice Encode the call to repay `amount` of `market.debt`.
    /// @dev Passing `amount == type(uint256).max` triggers a full share-based repay: the entire
    ///      borrow-share balance is burned, avoiding interest dust that an asset-denominated repay
    ///      would leave behind due to rounding.
    /// @param account The MarginAccount repaying the debt; used as `onBehalf`.
    /// @param market The (collateral, debt) pair identifying the target lending market.
    /// @param amount The amount of debt to repay in native decimals, or `type(uint256).max` to repay
    ///        all by shares.
    /// @return target The call target (always `lendingProtocol()`).
    /// @return value The call value. Always 0 for non-payable lending protocols.
    /// @return callData The calldata the account executes against `target`.
    function encodeRepay(address account, Market calldata market, uint256 amount)
        external
        view
        returns (address target, uint256 value, bytes memory callData);

    /// @notice Current position for `account` in `market`, as interest-accrued assets.
    /// @dev Both amounts are returned with accrued interest applied, not the raw stored values.
    ///      Callers can rely on these for an accurate snapshot of current obligations.
    /// @param account The MarginAccount to query.
    /// @param market The (collateral, debt) pair identifying the target lending market.
    /// @return collateralAmount The account's supplied collateral balance, in the collateral token's
    ///         native decimals.
    /// @return debtAmount The account's outstanding debt with accrued interest, in the debt token's
    ///         native decimals.
    function positionOf(address account, Market calldata market)
        external
        view
        returns (uint256 collateralAmount, uint256 debtAmount);

    /// @notice The market's maximum LTV (liquidation LTV), expressed as a WAD-typed `Ltv`
    ///         where 1e18 == 100%.
    /// @param market The (collateral, debt) pair identifying the target lending market.
    /// @return The liquidation LTV as an `Ltv` (WAD, 1e18 == 100%).
    function maxLtvWad(Market calldata market) external view returns (Ltv);

    /// @notice The account's current LTV in `market`, expressed as a WAD-typed `Ltv`
    ///         where 1e18 == 100%.
    /// @param account The MarginAccount to query.
    /// @param market The (collateral, debt) pair identifying the target lending market.
    /// @return The current LTV as an `Ltv` (WAD, 1e18 == 100%).
    function currentLtvWad(address account, Market calldata market) external view returns (Ltv);
}
