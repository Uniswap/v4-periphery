// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title Market
/// @author Uniswap Labs
/// @notice The lending-protocol-agnostic market key: the `(collateral, debt)` token pair every
///         margin flow is expressed in, plus the adapter-specific bytes that pin the pair to one
///         concrete venue market.
/// @dev The pair is typed because the router and the account read it on every leg (approvals,
///      balance deltas, wrap checks, Permit2 pulls, events) without consulting the adapter. `data`
///      is opaque to them: each lending adapter defines and decodes its own encoding, validates it
///      against the live venue on every call, and reverts (`InvalidMarketData`, `MarketNotSupported`,
///      or a venue-specific error) rather than fall back to a default market. Market selection is
///      permissionless: any market the venue has is routable through the adapter, so the caller is
///      responsible for vetting the market it names (oracle, interest model, liquidation LTV).
/// @param collateral The ERC-20 token used as collateral in the lending market.
/// @param debt The ERC-20 token borrowed as debt in the lending market.
/// @param data Adapter-specific market data, decoded by the adapter. See each adapter's NatSpec for
///        its encoding; adapters whose venue keys a market by the asset pair alone require it empty.
struct Market {
    Currency collateral;
    Currency debt;
    bytes data;
}
