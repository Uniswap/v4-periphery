// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title MarginActions
/// @author Uniswap Labs
/// @notice Action opcodes specific to margin operations, dispatched by `MarginRouter._handleAction`.
///         They extend the v4-periphery Actions space, whose opcodes end at `0x1b`, so margin
///         opcodes start at `0x1c`. Opcodes below `0x1c` fall through to the inherited V4Router
///         handlers (swap, settle, take, wrap, unwrap); opcodes at or above `0x1c` are handled
///         exclusively by the margin router.
///
///         There is no market/swap reconciliation opcode: that check is enforced when swap params
///         are built by `Market.toSwapParams`, so it cannot be skipped and needs no separate action.
library MarginActions {
    /// @notice Instructs the account to supply collateral to the lending protocol.
    ///         Decoded with `MarginCalldataDecoder.decodeAdapterMarketAmount`.
    uint256 internal constant ACCOUNT_SUPPLY_COLLATERAL = 0x1c;

    /// @notice Instructs the account to withdraw collateral from the lending protocol.
    ///         Decoded with `MarginCalldataDecoder.decodeAdapterMarketAmountReceiver`.
    uint256 internal constant ACCOUNT_WITHDRAW_COLLATERAL = 0x1d;

    /// @notice Instructs the account to borrow debt from the lending protocol.
    ///         Decoded with `MarginCalldataDecoder.decodeAdapterMarketAmountReceiver`.
    uint256 internal constant ACCOUNT_BORROW = 0x1e;

    /// @notice Instructs the account to repay debt to the lending protocol.
    ///         Decoded with `MarginCalldataDecoder.decodeAdapterMarketAmount`.
    uint256 internal constant ACCOUNT_REPAY = 0x1f;

    /// @notice Instructs the account to sweep a token balance to a recipient.
    ///         Decoded with `MarginCalldataDecoder.decodeSweep`.
    uint256 internal constant ACCOUNT_SWEEP = 0x20;

    /// @notice Asserts that the position's current LTV does not exceed a caller-supplied bound,
    ///         reverting `PositionUnhealthy` if it does. Decoded with
    ///         `MarginCalldataDecoder.decodeHealthCheck`.
    uint256 internal constant ASSERT_HEALTH = 0x21;
}
