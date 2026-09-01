// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MarketParams} from "morpho-blue/interfaces/IMorpho.sol";

import {Market} from "./Market.sol";
import {EnumerableMarketKeys} from "./EnumerableMarketKeys.sol";

/// @title MarketRegistry
/// @author Uniswap Labs
/// @notice Governed routing table mapping an agnostic `(collateral, debt)` pair to a concrete Morpho
///         `MarketParams`. The lending adapter's only storage concern. One canonical Morpho market is
///         registered per pair (token-pair-only, locked decision).
/// @dev Pairs a value map (`_inner`, the `MarketParams` per pair) with an `EnumerableMarketKeys` set
///      (`_keys`) that owns membership and enumeration. `has` on the key set is the single source of
///      truth, so `isSupported`/`resolve` and `count`/`page` can never disagree. Registration is
///      add-or-replace (no removal), so the set only grows.
/// @param _inner The nested mapping keyed by collateral then debt token; values are Morpho
///        `MarketParams`.
/// @param _keys The enumerable set of registered pairs. Access all state via the free functions
///        `register`, `resolve`, `isSupported`, `count`, and `page`.
struct MarketRegistry {
    mapping(Currency collateral => mapping(Currency debt => MarketParams)) _inner;
    EnumerableMarketKeys _keys;
}

using {register, resolve, isSupported, count, page} for MarketRegistry global;

/// @dev Thrown when resolving a `(collateral, debt)` pair that has no registered Morpho market.
///      Never returns a silent zero/default: an unregistered pair always reverts.
/// @param collateral The collateral currency that was not found.
/// @param debt The debt currency that was not found.
error MarketNotSupported(Currency collateral, Currency debt);

/// @notice Registers (or replaces) the canonical Morpho market for its `(collateral, debt)` pair. The
///         pair is derived from `mp.collateralToken` and `mp.loanToken`.
/// @dev The caller MUST gate access (e.g. an `Owner` guard); this free function performs no
///      authorization. The all-zero pair is refused so it never enters the set: a real Morpho market
///      always has non-zero tokens (the adapter also rejects a non-existent market), and enrolling a
///      null pair would surface a member `resolve` cannot serve.
/// @param self The registry storage to update.
/// @param mp The Morpho `MarketParams` to register; its `collateralToken` and `loanToken` fields
///        determine the routing key.
function register(MarketRegistry storage self, MarketParams memory mp) {
    if (mp.collateralToken == address(0) && mp.loanToken == address(0)) return;
    Currency collateral = Currency.wrap(mp.collateralToken);
    Currency debt = Currency.wrap(mp.loanToken);
    self._keys.add(collateral, debt); // no-op on a replacement
    self._inner[collateral][debt] = mp;
}

/// @notice Resolves a market pair to its registered `MarketParams`, reverting if unset.
/// @dev Never returns a zero or default market: an unregistered pair reverts `MarketNotSupported`.
/// @param self The registry storage to query.
/// @param market The `(collateral, debt)` pair to resolve.
/// @return mp The registered `MarketParams` for the pair.
function resolve(MarketRegistry storage self, Market memory market) view returns (MarketParams memory mp) {
    if (!self._keys.has(market.collateral, market.debt)) {
        revert MarketNotSupported(market.collateral, market.debt);
    }
    return self._inner[market.collateral][market.debt];
}

/// @notice True if the pair has a registered market in this registry.
/// @param self The registry storage to query.
/// @param market The `(collateral, debt)` pair to check.
/// @return True if the pair is registered.
function isSupported(MarketRegistry storage self, Market memory market) view returns (bool) {
    return self._keys.has(market.collateral, market.debt);
}

/// @notice The number of registered pairs.
/// @param self The registry storage to query.
/// @return The count of registered pairs.
function count(MarketRegistry storage self) view returns (uint256) {
    return self._keys.count();
}

/// @notice A bounded page of registered pairs (see `Market.paginate`).
/// @param self The registry storage to query.
/// @param offset The index of the first pair to return.
/// @param limit The maximum number of pairs to return.
/// @return A slice of the registered pairs, in registration order.
function page(MarketRegistry storage self, uint256 offset, uint256 limit) view returns (Market[] memory) {
    return self._keys.page(offset, limit);
}
