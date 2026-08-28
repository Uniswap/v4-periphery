// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {Market} from "./Market.sol";

/// @title MarketAllowlist
/// @author Uniswap Labs
/// @notice A governed boolean allowlist of routable `(collateral, debt)` pairs. This is the storage
///         concern shared by the lending adapters whose underlying protocol keys markets by asset
///         address rather than an adapter-chosen id (Aave v3, Compound v3): a pair is simply routable
///         or not. It is the boolean-valued sibling of `MarketRegistry` (which stores a Morpho
///         `MarketParams` value per pair) and follows the same type-driven shape. Adapters whose
///         protocol needs per-pair configuration beyond a flag (Morpho's `MarketParams`, Aave v4's
///         reserve-id route) keep their own value-typed table instead, since Solidity cannot express
///         one table generic over the value type.
/// @dev The adapter performs any protocol-specific validation (reserve exists, debt is the base
///      token, etc.) before calling `set`; this type only records routability.
/// @param _allowed The nested mapping keyed by collateral then debt token. Access via the free
///        functions `set`, `isAllowed`, and `requireAllowed`.
struct MarketAllowlist {
    mapping(Currency collateral => mapping(Currency debt => bool)) _allowed;
}

using {set, isAllowed, requireAllowed} for MarketAllowlist global;

/// @dev Thrown when a `(collateral, debt)` pair is not allowlisted, on any encode or read for the
///      pair. Shared by every adapter routing through a `MarketAllowlist`; never a silent default.
/// @param collateral The collateral currency that is not routable.
/// @param debt The debt currency that is not routable.
error MarketNotSupported(Currency collateral, Currency debt);

/// @notice Sets whether a `(collateral, debt)` pair is routable. The caller MUST gate access (e.g. an
///         `Owner` guard) and perform any protocol-specific validation first; this free function does
///         neither.
/// @param self The allowlist storage to update.
/// @param collateral The collateral token of the pair.
/// @param debt The debt token of the pair.
/// @param allowed True to allow routing; false to disable it.
function set(MarketAllowlist storage self, Currency collateral, Currency debt, bool allowed) {
    self._allowed[collateral][debt] = allowed;
}

/// @notice True if the pair is currently routable.
/// @param self The allowlist storage to query.
/// @param market The `(collateral, debt)` pair to check.
/// @return True if the pair is allowlisted.
function isAllowed(MarketAllowlist storage self, Market memory market) view returns (bool) {
    return self._allowed[market.collateral][market.debt];
}

/// @notice Reverts `MarketNotSupported` unless the pair is allowlisted.
/// @param self The allowlist storage to query.
/// @param market The `(collateral, debt)` pair to require.
function requireAllowed(MarketAllowlist storage self, Market memory market) view {
    if (!self._allowed[market.collateral][market.debt]) {
        revert MarketNotSupported(market.collateral, market.debt);
    }
}
