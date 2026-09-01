// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {Market, paginate} from "./Market.sol";

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
///      token, etc.) before calling `set`; this type only records routability. The `_keys` array and
///      `_index` map make the allowlist enumerable (`count`/`page`) so an offchain market picker can
///      list the routable pairs without replaying `MarketSet` logs; they are maintained in `set`.
/// @param _allowed The nested mapping keyed by collateral then debt token.
/// @param _keys The dense list of currently-allowed pairs, in insertion order (a removal swaps the
///        last entry into the freed slot, so order is not stable across removals).
/// @param _index The 1-based position of each allowed pair in `_keys` (0 means absent), used for O(1)
///        removal. Access all state via the free functions `set`, `isAllowed`, `requireAllowed`,
///        `count`, and `page`.
struct MarketAllowlist {
    mapping(Currency collateral => mapping(Currency debt => bool)) _allowed;
    Market[] _keys;
    mapping(Currency collateral => mapping(Currency debt => uint256)) _index;
}

using {set, isAllowed, requireAllowed, count, page} for MarketAllowlist global;

/// @dev Thrown when a `(collateral, debt)` pair is not allowlisted, on any encode or read for the
///      pair. Shared by every adapter routing through a `MarketAllowlist`; never a silent default.
/// @param collateral The collateral currency that is not routable.
/// @param debt The debt currency that is not routable.
error MarketNotSupported(Currency collateral, Currency debt);

/// @notice Sets whether a `(collateral, debt)` pair is routable, keeping the enumerable key set in
///         sync. The caller MUST gate access (e.g. an `Owner` guard) and perform any protocol-specific
///         validation first; this free function does neither.
/// @dev Idempotent: re-setting a pair to its current state is a no-op for the key set. Enabling a new
///      pair appends it to `_keys`; disabling an allowed pair removes it via swap-and-pop.
/// @param self The allowlist storage to update.
/// @param collateral The collateral token of the pair.
/// @param debt The debt token of the pair.
/// @param allowed True to allow routing; false to disable it.
function set(MarketAllowlist storage self, Currency collateral, Currency debt, bool allowed) {
    bool was = self._allowed[collateral][debt];
    if (allowed && !was) {
        self._keys.push(Market({collateral: collateral, debt: debt}));
        self._index[collateral][debt] = self._keys.length; // 1-based
    } else if (!allowed && was) {
        uint256 idx = self._index[collateral][debt]; // 1-based, non-zero here
        uint256 last = self._keys.length;
        if (idx != last) {
            Market memory moved = self._keys[last - 1];
            self._keys[idx - 1] = moved;
            self._index[moved.collateral][moved.debt] = idx;
        }
        self._keys.pop();
        delete self._index[collateral][debt];
    }
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

/// @notice The number of currently-allowed pairs.
/// @param self The allowlist storage to query.
/// @return The count of routable pairs.
function count(MarketAllowlist storage self) view returns (uint256) {
    return self._keys.length;
}

/// @notice A bounded page of currently-allowed pairs (see `Market.paginate`).
/// @param self The allowlist storage to query.
/// @param offset The index of the first pair to return.
/// @param limit The maximum number of pairs to return.
/// @return A slice of the allowed pairs, in storage order.
function page(MarketAllowlist storage self, uint256 offset, uint256 limit) view returns (Market[] memory) {
    return paginate(self._keys, offset, limit);
}
