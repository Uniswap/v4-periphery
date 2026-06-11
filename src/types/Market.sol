// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice The lending-protocol-agnostic market descriptor: the `(collateral, debt)` token pair.
/// @dev Token-pair-only by design: there is no `marketId` field.
///      The singleton lending adapter resolves the pair to a concrete protocol market internally.
struct Market {
    Currency collateral;
    Currency debt;
}

using {eq, hasCurrencies, toSwapParams} for Market global;

/// @notice Thrown when a v4 pool's currencies do not match the market's `(collateral, debt)` pair,
///         or the requested swap input is not one of the market's currencies.
error MarketSwapMismatch();

/// @notice Structural equality: both `collateral` and `debt` match.
function eq(Market memory self, Market memory other) pure returns (bool) {
    return self.collateral == other.collateral && self.debt == other.debt;
}

/// @notice True iff the unordered pair `{a, b}` equals the market's `{collateral, debt}`.
function hasCurrencies(Market memory self, Currency a, Currency b) pure returns (bool) {
    return (a == self.collateral && b == self.debt) || (a == self.debt && b == self.collateral);
}

/// @notice The single choke point that reconciles a v4 pool with this market and derives swap
///         direction. Every margin flow builds its swap params here, so a pool/market currency
///         mismatch is structurally unable to reach the lending legs.
/// @dev This is a runtime check (Solidity cannot make set-equality a compile-time guarantee); its
///      value is locality and unavoidability, not compile-time elimination.
/// @param input The currency sold into the pool. Open/increase sell the debt (borrow debt, buy
///        collateral); close/decrease sell the collateral (sell collateral, buy debt to repay).
///        Must be one of the market's two currencies.
/// @param amountSpecified Negative for exact-input, positive for exact-output (v4 convention).
/// @param sqrtPriceLimitX96 The swap price limit.
/// @param key The v4 pool to route through; its `{currency0, currency1}` MUST equal the market pair.
/// @return params Validated v4 `SwapParams`; `zeroForOne` is derived from `input` and pool ordering.
function toSwapParams(
    Market memory self,
    Currency input,
    int256 amountSpecified,
    uint160 sqrtPriceLimitX96,
    PoolKey memory key
) pure returns (SwapParams memory params) {
    // the pool must trade exactly this market's two currencies (order-independent)
    if (!hasCurrencies(self, key.currency0, key.currency1)) revert MarketSwapMismatch();
    // the swap input must be one of the market's currencies
    if (!(input == self.collateral || input == self.debt)) revert MarketSwapMismatch();
    // zeroForOne is a pure function of which currency is sold and the canonical pool ordering
    params = SwapParams({
        zeroForOne: input == key.currency0,
        amountSpecified: amountSpecified,
        sqrtPriceLimitX96: sqrtPriceLimitX96
    });
}
