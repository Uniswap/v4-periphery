// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Action opcodes specific to margin operations, dispatched by MarginRouter._handleAction.
///         They extend the v4-periphery Actions space, whose opcodes end at 0x1b, so margin opcodes
///         start at 0x1c. Opcodes below 0x1c fall through to the inherited V4Router handlers (swap,
///         settle, take, wrap, unwrap); opcodes at or above 0x1c are handled by the margin router.
///
///         There is no market/swap reconciliation opcode: that check is enforced when the swap
///         params are built, by the single Market.toSwapParams choke point, so it cannot be skipped
///         and needs no separate runtime action.
library MarginActions {
    uint256 internal constant ACCOUNT_SUPPLY_COLLATERAL = 0x1c;
    uint256 internal constant ACCOUNT_WITHDRAW_COLLATERAL = 0x1d;
    uint256 internal constant ACCOUNT_BORROW = 0x1e;
    uint256 internal constant ACCOUNT_REPAY = 0x1f;
    uint256 internal constant ACCOUNT_SWEEP = 0x20;
    uint256 internal constant ASSERT_HEALTH = 0x21;
}
