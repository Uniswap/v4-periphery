// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {Market, paginate} from "./Market.sol";

/// @title EnumerableMarketKeys
/// @author Uniswap Labs
/// @notice The shared key-tracking half of a lending adapter's market table: a dense, enumerable set of
///         `(collateral, debt)` pairs with O(1) membership, insertion, and removal. Each adapter's
///         market table pairs this with its own value map (a bool allowlist, a Morpho `MarketParams`
///         registry, or an Aave v4 reserve-id route) that Solidity cannot make generic over the value
///         type; embedding this struct keeps the swap-and-pop / 1-based-index bookkeeping in one tested
///         place instead of a hand-written copy per table.
/// @dev All state is maintained by the free functions below; callers never touch `_keys`/`_index`
///      directly. This primitive holds no policy of its own (it will enroll any pair, including the
///      all-zero pair) so each embedding type can impose its own membership rules; `has` is the single
///      source of truth for membership, so it never disagrees with `count`/`page`.
/// @param _keys The dense list of member pairs, in insertion order. A removal swaps the last entry into
///        the freed slot, so order is not stable across removals; treat a page as a snapshot.
/// @param _index The 1-based position of each member in `_keys` (0 means absent), for O(1) removal.
struct EnumerableMarketKeys {
    Market[] _keys;
    mapping(Currency collateral => mapping(Currency debt => uint256)) _index;
}

using {add, remove, has, count, page} for EnumerableMarketKeys global;

/// @notice Adds `(collateral, debt)` to the set. Idempotent: adding a present pair is a no-op.
/// @param self The key set to update.
/// @param collateral The collateral token of the pair.
/// @param debt The debt token of the pair.
function add(EnumerableMarketKeys storage self, Currency collateral, Currency debt) {
    if (self._index[collateral][debt] == 0) {
        self._keys.push(Market({collateral: collateral, debt: debt}));
        self._index[collateral][debt] = self._keys.length; // 1-based
    }
}

/// @notice Removes `(collateral, debt)` from the set, swapping the last entry into the freed slot.
///         Idempotent: removing an absent pair is a no-op.
/// @param self The key set to update.
/// @param collateral The collateral token of the pair.
/// @param debt The debt token of the pair.
function remove(EnumerableMarketKeys storage self, Currency collateral, Currency debt) {
    uint256 idx = self._index[collateral][debt]; // 1-based, 0 when absent
    if (idx == 0) return;
    uint256 last = self._keys.length;
    if (idx != last) {
        Market memory moved = self._keys[last - 1];
        self._keys[idx - 1] = moved;
        self._index[moved.collateral][moved.debt] = idx;
    }
    self._keys.pop();
    delete self._index[collateral][debt];
}

/// @notice True if `(collateral, debt)` is a member.
/// @param self The key set to query.
/// @param collateral The collateral token of the pair.
/// @param debt The debt token of the pair.
/// @return True if the pair is in the set.
function has(EnumerableMarketKeys storage self, Currency collateral, Currency debt) view returns (bool) {
    return self._index[collateral][debt] != 0;
}

/// @notice The number of members.
/// @param self The key set to query.
/// @return The member count.
function count(EnumerableMarketKeys storage self) view returns (uint256) {
    return self._keys.length;
}

/// @notice A bounded page of members (see `Market.paginate`).
/// @param self The key set to query.
/// @param offset The index of the first member to return.
/// @param limit The maximum number of members to return.
/// @return A slice of the members, in storage order.
function page(EnumerableMarketKeys storage self, uint256 offset, uint256 limit) view returns (Market[] memory) {
    return paginate(self._keys, offset, limit);
}
