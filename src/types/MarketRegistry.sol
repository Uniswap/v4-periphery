// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MarketParams} from "morpho-blue/interfaces/IMorpho.sol";

import {Market} from "./Market.sol";

/// @notice Governed routing table mapping an agnostic `(collateral, debt)` pair to a concrete Morpho
///         `MarketParams`. The lending adapter's only storage concern. One canonical
///         market per pair (token-pair-only, locked decision).
struct MarketRegistry {
    mapping(Currency collateral => mapping(Currency debt => MarketParams)) _inner;
}

using {register, resolve, isSupported} for MarketRegistry global;

/// @notice Thrown when resolving a `(collateral, debt)` pair that has no registered market.
error MarketNotSupported(Currency collateral, Currency debt);

/// @notice Registers (or replaces) the canonical Morpho market for its `(collateral, debt)` pair.
/// @dev The pair is derived from `mp.collateralToken` / `mp.loanToken`. Caller MUST gate access
///      (e.g. an `Owner` guard); this free function performs no authorization.
function register(MarketRegistry storage self, MarketParams memory mp) returns (MarketRegistry storage) {
    self._inner[Currency.wrap(mp.collateralToken)][Currency.wrap(mp.loanToken)] = mp;
    return self;
}

/// @notice Resolves a market pair to its registered `MarketParams`, reverting if unset.
/// @dev Never returns a zero or default market: an unregistered pair reverts `MarketNotSupported`.
///      A registered leverage market always has non-zero collateral and loan tokens.
function resolve(MarketRegistry storage self, Market memory market) view returns (MarketParams memory mp) {
    mp = self._inner[market.collateral][market.debt];
    if (mp.collateralToken == address(0) && mp.loanToken == address(0)) {
        revert MarketNotSupported(market.collateral, market.debt);
    }
}

/// @notice True if the pair has a registered market.
function isSupported(MarketRegistry storage self, Market memory market) view returns (bool) {
    MarketParams storage mp = self._inner[market.collateral][market.debt];
    return !(mp.collateralToken == address(0) && mp.loanToken == address(0));
}
