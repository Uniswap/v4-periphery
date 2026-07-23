// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MarketParams} from "morpho-blue/interfaces/IMorpho.sol";

import {Market} from "./Market.sol";

/// @title MarketRegistry
/// @author Uniswap Labs
/// @notice Governed routing table mapping an agnostic `(collateral, debt)` pair to a concrete
///         Morpho `MarketParams`. The lending adapter's only storage concern. One canonical Morpho
///         market is registered per pair (token-pair-only, locked decision).
/// @param _inner The nested mapping keyed by collateral then debt token; values are Morpho
///        `MarketParams`. Access via the free functions `register`, `resolve`, and `isSupported`.
struct MarketRegistry {
    mapping(Currency collateral => mapping(Currency debt => MarketParams)) _inner;
}

using {register, resolve, isSupported} for MarketRegistry global;

/// @dev Thrown when resolving a `(collateral, debt)` pair that has no registered Morpho market.
///      Never returns a silent zero/default: an unregistered pair always reverts.
/// @param collateral The collateral currency that was not found.
/// @param debt The debt currency that was not found.
error MarketNotSupported(Currency collateral, Currency debt);

/// @notice Registers (or replaces) the canonical Morpho market for its `(collateral, debt)` pair.
///         The pair is derived from `mp.collateralToken` and `mp.loanToken`.
/// @dev The caller MUST gate access (e.g. an `Owner` guard); this free function performs no
///      authorization.
/// @param self The registry storage to update.
/// @param mp The Morpho `MarketParams` to register; its `collateralToken` and `loanToken` fields
///        determine the routing key.
/// @return The same storage reference, for chaining.
function register(MarketRegistry storage self, MarketParams memory mp) returns (MarketRegistry storage) {
    self._inner[Currency.wrap(mp.collateralToken)][Currency.wrap(mp.loanToken)] = mp;
    return self;
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
