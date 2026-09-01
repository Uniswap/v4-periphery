// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MarketParams} from "morpho-blue/interfaces/IMorpho.sol";

import {Market, paginate} from "./Market.sol";

/// @title MarketRegistry
/// @author Uniswap Labs
/// @notice Governed routing table mapping an agnostic `(collateral, debt)` pair to a concrete
///         Morpho `MarketParams`. The lending adapter's only storage concern. One canonical Morpho
///         market is registered per pair (token-pair-only, locked decision).
/// @dev The `_keys` array and `_index` map make the registry enumerable (`count`/`page`) so an
///      offchain market picker can list the registered pairs without replaying `MarketSet` logs; they
///      are maintained in `register`. Registration is add-or-replace (no removal), so `_keys` only
///      grows and a page is stable except for a re-registration overwriting a pair's `MarketParams`.
/// @param _inner The nested mapping keyed by collateral then debt token; values are Morpho
///        `MarketParams`.
/// @param _keys The dense list of registered pairs, in registration order.
/// @param _index The 1-based position of each pair in `_keys` (0 means unregistered), used to dedupe a
///        re-registration. Access all state via the free functions `register`, `resolve`,
///        `isSupported`, `count`, and `page`.
struct MarketRegistry {
    mapping(Currency collateral => mapping(Currency debt => MarketParams)) _inner;
    Market[] _keys;
    mapping(Currency collateral => mapping(Currency debt => uint256)) _index;
}

using {register, resolve, isSupported, count, page} for MarketRegistry global;

/// @dev Thrown when resolving a `(collateral, debt)` pair that has no registered Morpho market.
///      Never returns a silent zero/default: an unregistered pair always reverts.
/// @param collateral The collateral currency that was not found.
/// @param debt The debt currency that was not found.
error MarketNotSupported(Currency collateral, Currency debt);

/// @notice Registers (or replaces) the canonical Morpho market for its `(collateral, debt)` pair,
///         keeping the enumerable key set in sync. The pair is derived from `mp.collateralToken` and
///         `mp.loanToken`.
/// @dev The caller MUST gate access (e.g. an `Owner` guard); this free function performs no
///      authorization. A first registration for a pair appends it to `_keys`; a replacement overwrites
///      the stored `MarketParams` without touching `_keys`.
/// @param self The registry storage to update.
/// @param mp The Morpho `MarketParams` to register; its `collateralToken` and `loanToken` fields
///        determine the routing key.
function register(MarketRegistry storage self, MarketParams memory mp) {
    Currency collateral = Currency.wrap(mp.collateralToken);
    Currency debt = Currency.wrap(mp.loanToken);
    // The all-zero pair is the `isSupported`/`resolve` "unregistered" sentinel, so never enroll it into the
    // enumerable key set; otherwise `count`/`page` would report a pair those functions deny. A real Morpho
    // market always has non-zero tokens (the adapter also rejects a non-existent market), so this only
    // guards the degenerate direct-use case.
    if (mp.collateralToken == address(0) && mp.loanToken == address(0)) return;
    if (self._index[collateral][debt] == 0) {
        self._keys.push(Market({collateral: collateral, debt: debt}));
        self._index[collateral][debt] = self._keys.length; // 1-based
    }
    self._inner[collateral][debt] = mp;
}

/// @notice Resolves a market pair to its registered `MarketParams`, reverting if unset.
/// @dev Never returns a zero or default market: an unregistered pair reverts `MarketNotSupported`.
///      A registered leverage market always has non-zero collateral and loan tokens.
/// @param self The registry storage to query.
/// @param market The `(collateral, debt)` pair to resolve.
/// @return mp The registered `MarketParams` for the pair.
function resolve(MarketRegistry storage self, Market memory market) view returns (MarketParams memory mp) {
    mp = self._inner[market.collateral][market.debt];
    if (mp.collateralToken == address(0) && mp.loanToken == address(0)) {
        revert MarketNotSupported(market.collateral, market.debt);
    }
}

/// @notice True if the pair has a registered market in this registry.
/// @param self The registry storage to query.
/// @param market The `(collateral, debt)` pair to check.
/// @return True if a non-zero `MarketParams` is stored for the pair.
function isSupported(MarketRegistry storage self, Market memory market) view returns (bool) {
    MarketParams storage mp = self._inner[market.collateral][market.debt];
    return !(mp.collateralToken == address(0) && mp.loanToken == address(0));
}

/// @notice The number of registered pairs.
/// @param self The registry storage to query.
/// @return The count of registered pairs.
function count(MarketRegistry storage self) view returns (uint256) {
    return self._keys.length;
}

/// @notice A bounded page of registered pairs (see `Market.paginate`).
/// @param self The registry storage to query.
/// @param offset The index of the first pair to return.
/// @param limit The maximum number of pairs to return.
/// @return A slice of the registered pairs, in registration order.
function page(MarketRegistry storage self, uint256 offset, uint256 limit) view returns (Market[] memory) {
    return paginate(self._keys, offset, limit);
}
