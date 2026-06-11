// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The direction of a leveraged spot position.
/// @dev Replaces a boolean long/short flag so margin flows branch exhaustively and a stray
///      `true`/`false` can never be mis-read. `Long`: the exposure asset is the collateral
///      (borrow the quote, buy more exposure). `Short`: the exposure asset is the debt
///      (borrow the exposure, sell it for the quote/collateral).
enum Direction {
    Long,
    Short
}
