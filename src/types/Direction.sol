// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Direction
/// @author Uniswap Labs
/// @notice The direction of a leveraged spot position.
/// @dev Replaces a boolean long/short flag so margin flows can branch exhaustively and a stray
///      `true`/`false` can never be mis-read as the wrong direction.
///
///      `Long`: the exposure asset is the collateral token (borrow the quote/debt, buy more of
///      the collateral as exposure).
///
///      `Short`: the exposure asset is the debt token (borrow the exposure, sell it for the
///      quote/collateral).
enum Direction {
    Long,
    Short
}
