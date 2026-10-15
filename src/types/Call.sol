// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Call
/// @author Uniswap Labs
/// @notice One call a `MarginAccount` performs against an adapter's `lendingProtocol()`. An adapter
///         encodes each position step as a sequence of these, so a venue that needs more than one
///         call per step (Aave's explicit collateral enable after a supply) expresses it in the
///         sequence, and the account stays a sequencer that knows nothing venue-specific. An empty
///         sequence is the skip signal a repay encoder returns for a debt-free account.
/// @param value The native value to send. Zero for every in-tree venue; the account forwards whatever
///        the adapter encodes.
/// @param data The calldata.
struct Call {
    uint256 value;
    bytes data;
}
