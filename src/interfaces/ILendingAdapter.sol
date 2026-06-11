// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Market} from "../types/Market.sol";
import {Ltv} from "../types/Ltv.sol";

/// @notice Lending-protocol-agnostic surface the margin router and account depend on. ONE singleton
///         instance per lending protocol; the specific market is selected by the `Market`
///         (collateral, debt) token pair passed to each call and resolved internally.
/// @dev The adapter is an ENCODER: each `encode*` returns the call the `MarginAccount` performs as
///      itself (`account == msg.sender == position owner`), so no delegated authorization is ever
///      required. Authority-bearing fields (`onBehalf`, `receiver`) are owned and re-validated by the
///      account; the account does NOT trust adapter-encoded bytes for them. Encode and read calls
///      revert `MarketNotSupported` (declared in `MarketRegistry`) for unrouted pairs, never a
///      silent default market.
interface ILendingAdapter {
    /// @notice The lending protocol SINGLETON the account must call (the target of the account's
    ///         CALL). One address for every market this adapter routes to (e.g. Morpho Blue).
    function lendingProtocol() external view returns (address);

    /// @notice Whether the adapter can route `market` to a vetted protocol market.
    function isSupportedMarket(Market calldata market) external view returns (bool);

    /// @notice Encode the call to supply `amount` of `market.collateral` with `onBehalf = account`.
    /// @return target The call target (always `lendingProtocol()`).
    /// @return value The call value. Always 0 for Morpho (non-payable); the account treats non-zero
    ///         as a bug.
    /// @return callData The calldata the account executes against `target`.
    function encodeSupplyCollateral(address account, Market calldata market, uint256 amount)
        external
        view
        returns (address target, uint256 value, bytes memory callData);

    /// @notice Encode the call to withdraw `amount` of `market.collateral` to `receiver`.
    function encodeWithdrawCollateral(address account, Market calldata market, uint256 amount, address receiver)
        external
        view
        returns (address target, uint256 value, bytes memory callData);

    /// @notice Encode the call to borrow `amount` of `market.debt` to `receiver`.
    function encodeBorrow(address account, Market calldata market, uint256 amount, address receiver)
        external
        view
        returns (address target, uint256 value, bytes memory callData);

    /// @notice Encode the call to repay `amount` of `market.debt`.
    /// @dev `amount == type(uint256).max` => repay-all (shares-based) to avoid interest dust.
    function encodeRepay(address account, Market calldata market, uint256 amount)
        external
        view
        returns (address target, uint256 value, bytes memory callData);

    /// @notice Current position for `account` in `market`, as interest-ACCRUED assets, keyed by the
    ///         account address.
    function positionOf(address account, Market calldata market)
        external
        view
        returns (uint256 collateralAmount, uint256 debtAmount);

    /// @notice The market's max LTV (liquidation LTV), as a WAD-typed `Ltv`.
    function maxLtvWad(Market calldata market) external view returns (Ltv);

    /// @notice The account's current LTV in `market`, as a WAD-typed `Ltv`.
    function currentLtvWad(address account, Market calldata market) external view returns (Ltv);
}
