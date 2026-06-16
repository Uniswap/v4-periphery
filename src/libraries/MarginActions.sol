// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title MarginActions
/// @author Uniswap Labs
/// @notice Action opcodes specific to margin operations, dispatched by `MarginRouter._handleAction`.
///         The v4-periphery Actions space currently ends at `0x1b`. Rather than packing margin
///         opcodes immediately against it, they start at `0x30`, leaving `0x1c`-`0x2f` free for
///         future core Actions (swap, settle, take, and similar) to grow into without colliding
///         with the margin range. Opcodes below `0x30` fall through to the inherited V4Router
///         handlers (swap, settle, take, wrap, unwrap); opcodes at or above `0x30` are handled
///         exclusively by the margin router.
///
///         There is no market/swap reconciliation opcode: that check is enforced when swap params
///         are built by `Market.toSwapParams`, so it cannot be skipped and needs no separate action.
library MarginActions {
    /// @notice Instructs the account to supply collateral to the lending protocol.
    ///         Decoded with `MarginCalldataDecoder.decodeAdapterMarketAmount`.
    uint256 internal constant ACCOUNT_SUPPLY_COLLATERAL = 0x30;

    /// @notice Instructs the account to withdraw collateral from the lending protocol.
    ///         Decoded with `MarginCalldataDecoder.decodeAdapterMarketAmountReceiver`.
    uint256 internal constant ACCOUNT_WITHDRAW_COLLATERAL = 0x31;

    /// @notice Instructs the account to borrow debt from the lending protocol.
    ///         Decoded with `MarginCalldataDecoder.decodeAdapterMarketAmountReceiver`.
    uint256 internal constant ACCOUNT_BORROW = 0x32;

    /// @notice Instructs the account to repay debt to the lending protocol.
    ///         Decoded with `MarginCalldataDecoder.decodeAdapterMarketAmount`.
    uint256 internal constant ACCOUNT_REPAY = 0x33;

    /// @notice Instructs the account to sweep a token balance to a recipient.
    ///         Decoded with `MarginCalldataDecoder.decodeSweep`.
    uint256 internal constant ACCOUNT_SWEEP = 0x34;

    /// @notice Asserts that the position's current LTV does not exceed a caller-supplied bound,
    ///         reverting `PositionUnhealthy` if it does. Decoded with
    ///         `MarginCalldataDecoder.decodeHealthCheck`.
    uint256 internal constant ASSERT_HEALTH = 0x35;

    /// @notice Asserts that the router holds at least a minimum credit in a currency, i.e. an
    ///         exact-output swap delivered the full requested amount, reverting `IncompleteFill` on a
    ///         partial fill. Decoded with `MarginCalldataDecoder.decodeFillCheck`.
    uint256 internal constant ASSERT_FILL = 0x36;
}
