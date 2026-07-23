// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title MarginActions
/// @author Uniswap Labs
/// @notice Action opcodes specific to margin operations, dispatched by `MarginRouter._handleAction`.
///         The v4-periphery Actions space currently ends at `0x1b`. Rather than packing margin
///         opcodes immediately against it, they start at `0x30`, leaving `0x1c`-`0x2f` free for
///         future core Actions (swap, settle, take, and similar) to grow into without colliding
///         with the margin range. Opcodes below `0x30` fall through to the inherited V4Router
///         handlers (swap, settle, take), except `SWEEP`/`WRAP`/`UNWRAP` which V4Router does not
///         handle and `MarginRouter` intercepts with PositionManager-identical semantics; opcodes
///         at or above `0x30` are handled exclusively by the margin router.
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

    /// @notice Sets the active account for the subsequent account-scoped actions in an `execute`
    ///         plan, deploying it if it does not yet exist. The account is always derived from the
    ///         authenticated caller and the decoded `subId`, never from a caller-supplied address,
    ///         so a plan can only ever operate on the caller's own accounts. May appear multiple
    ///         times in one plan to drive multiple sub-accounts (e.g. cross-account migration).
    ///         Decoded with `MarginCalldataDecoder.decodeSubId`.
    uint256 internal constant SET_ACCOUNT = 0x37;

    /// @notice Transfers a token into the active account: pulled from the caller via Permit2 when
    ///         `payerIsUser` is true, or moved from the router's own balance when false. Enables
    ///         repay-from-wallet and native-equity flows. Unlike other opcodes, an encoded `0`
    ///         amount reverts rather than resolving to a full-balance sentinel (`OPEN_DELTA`);
    ///         `CONTRACT_BALANCE` is honored only on the router-balance path. Decoded with
    ///         `MarginCalldataDecoder.decodePull`.
    uint256 internal constant PULL_TO_ACCOUNT = 0x38;
}
