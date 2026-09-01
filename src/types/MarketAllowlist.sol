// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {Market} from "./Market.sol";
import {EnumerableMarketKeys} from "./EnumerableMarketKeys.sol";

/// @title MarketAllowlist
/// @author Uniswap Labs
/// @notice A governed boolean allowlist of routable `(collateral, debt)` pairs. This is the storage
///         concern shared by the lending adapters whose underlying protocol keys markets by asset
///         address rather than an adapter-chosen id (Aave v3, Compound v3): a pair is simply routable
///         or not. It is the flag-only sibling of `MarketRegistry` (which stores a Morpho `MarketParams`
///         value per pair); both are thin wrappers over `EnumerableMarketKeys`, which owns the
///         routability set. Adapters whose protocol needs per-pair configuration beyond a flag (Morpho's
///         `MarketParams`, Aave v4's reserve-id route) pair the key set with their own value table.
/// @dev Membership IS enumeration: allowed pairs are exactly the members of the embedded key set, so
///      `isAllowed`/`requireAllowed` and `count`/`page` can never disagree. The adapter performs any
///      protocol-specific validation (reserve exists, debt is the base token, etc.) before calling
///      `set`; this type only records routability.
/// @param _keys The enumerable set of allowed pairs. Access all state via the free functions `set`,
///        `isAllowed`, `requireAllowed`, `count`, and `page`.
struct MarketAllowlist {
    EnumerableMarketKeys _keys;
}

using {set, isAllowed, requireAllowed, count, page} for MarketAllowlist global;

/// @dev Thrown when a `(collateral, debt)` pair is not allowlisted, on any encode or read for the
///      pair. Shared by every adapter routing through a `MarketAllowlist`; never a silent default.
/// @param collateral The collateral currency that is not routable.
/// @param debt The debt currency that is not routable.
error MarketNotSupported(Currency collateral, Currency debt);

/// @notice Sets whether a `(collateral, debt)` pair is routable. The caller MUST gate access (e.g. an
///         `Owner` guard) and perform any protocol-specific validation first; this free function does
///         neither. Idempotent: re-setting a pair to its current state is a no-op.
/// @param self The allowlist storage to update.
/// @param collateral The collateral token of the pair.
/// @param debt The debt token of the pair.
/// @param allowed True to allow routing; false to disable it.
function set(MarketAllowlist storage self, Currency collateral, Currency debt, bool allowed) {
    if (allowed) self._keys.add(collateral, debt);
    else self._keys.remove(collateral, debt);
}

/// @notice True if the pair is currently routable.
/// @param self The allowlist storage to query.
/// @param market The `(collateral, debt)` pair to check.
/// @return True if the pair is allowlisted.
function isAllowed(MarketAllowlist storage self, Market memory market) view returns (bool) {
    return self._keys.has(market.collateral, market.debt);
}

/// @notice Reverts `MarketNotSupported` unless the pair is allowlisted.
/// @param self The allowlist storage to query.
/// @param market The `(collateral, debt)` pair to require.
function requireAllowed(MarketAllowlist storage self, Market memory market) view {
    if (!self._keys.has(market.collateral, market.debt)) {
        revert MarketNotSupported(market.collateral, market.debt);
    }
}

/// @notice The number of currently-allowed pairs.
/// @param self The allowlist storage to query.
/// @return The count of routable pairs.
function count(MarketAllowlist storage self) view returns (uint256) {
    return self._keys.count();
}

/// @notice A bounded page of currently-allowed pairs (see `Market.paginate`).
/// @param self The allowlist storage to query.
/// @param offset The index of the first pair to return.
/// @param limit The maximum number of pairs to return.
/// @return A slice of the allowed pairs, in storage order.
function page(MarketAllowlist storage self, uint256 offset, uint256 limit) view returns (Market[] memory) {
    return self._keys.page(offset, limit);
}
