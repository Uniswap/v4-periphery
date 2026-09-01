// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

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

/// @notice A bounded slice of a stored market-key array, for onchain enumeration.
/// @dev Returns up to `limit` markets starting at `offset`. An `offset` at or beyond the array length
///      yields an empty array, and the tail is clamped, so `limit` may run past the end safely. The
///      order is the array's storage order, which is not stable across removals (adapters that support
///      un-registering a market swap-and-pop), so treat a page as a snapshot, not a stable index.
/// @param self The stored market-key array to page over.
/// @param offset The index of the first market to return.
/// @param limit The maximum number of markets to return.
/// @return page The requested slice, in storage order.
function paginate(Market[] storage self, uint256 offset, uint256 limit) view returns (Market[] memory page) {
    uint256 len = self.length;
    if (offset >= len) return new Market[](0);
    uint256 remaining = len - offset;
    uint256 n = limit < remaining ? limit : remaining;
    page = new Market[](n);
    for (uint256 i = 0; i < n; ++i) {
        page[i] = self[offset + i];
    }
}
