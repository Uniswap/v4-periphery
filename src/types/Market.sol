// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title Market
/// @author Uniswap Labs
/// @notice The lending-protocol-agnostic market descriptor: the `(collateral, debt)` token pair.
/// @dev Token-pair-only by design: there is no `marketId` field. The singleton lending adapter
///      resolves the pair to a concrete protocol market internally.
/// @param collateral The ERC-20 token used as collateral in the lending market.
/// @param debt The ERC-20 token borrowed as debt in the lending market.
struct Market {
    Currency collateral;
    Currency debt;
}

using {eq, hasCurrencies, toSwapParams} for Market global;

/// @dev Thrown when a v4 pool's currencies do not match the market's `(collateral, debt)` pair,
///      or the requested swap input is not one of the market's currencies. Prevents a pool/market
///      currency mismatch from reaching the lending legs.
error MarketSwapMismatch();

/// @notice Structural equality check: both `collateral` and `debt` match.
/// @param self The market to compare.
/// @param other The market to compare against.
/// @return True if both fields match exactly.
function eq(Market memory self, Market memory other) pure returns (bool) {
    return self.collateral == other.collateral && self.debt == other.debt;
}

/// @notice True iff the unordered pair `{a, b}` equals the market's `{collateral, debt}` pair.
///         Order-insensitive: `{a, b}` and `{b, a}` both match.
/// @param self The market whose currency set is checked.
/// @param a One of the two currencies to test.
/// @param b The other currency to test.
/// @return True if `{a, b}` is the same unordered set as `{collateral, debt}`.
function hasCurrencies(Market memory self, Currency a, Currency b) pure returns (bool) {
    return (a == self.collateral && b == self.debt) || (a == self.debt && b == self.collateral);
}

/// @notice The single choke point that reconciles a v4 pool with this market and derives swap
///         direction. Every margin flow builds its swap params here, so a pool/market currency
///         mismatch is structurally unable to reach the lending legs.
/// @dev This is a runtime check (Solidity cannot make set-equality a compile-time guarantee); its
///      value is locality and unavoidability: every swap passes through this function and it cannot
///      be bypassed.
/// @param self The market that must match the pool's currency pair.
/// @param input The currency sold into the pool. Open and increase flows sell the debt (borrow
///        debt, buy collateral); close and decrease flows sell the collateral (buy debt to repay).
///        Must be exactly one of the market's two currencies.
/// @param amountSpecified Negative for exact-input, positive for exact-output (v4 convention).
/// @param sqrtPriceLimitX96 The worst acceptable pool price for the swap, in Q64.96 format.
///        Pass 0 to use no price limit.
/// @param key The v4 pool to route through; its `{currency0, currency1}` must equal the market
///        pair (order-independent).
/// @return params Validated v4 `SwapParams`; `zeroForOne` is derived from `input` and pool
///         ordering.
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
        zeroForOne: input == key.currency0, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96
    });
}
