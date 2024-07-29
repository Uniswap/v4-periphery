// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

/// @notice Library to define different pool actions.
/// @dev These are suggested common commands, however additional commands should be defined as required
library Actions {
    // pool actions
    uint256 constant INCREASE_LIQUIDITY = 0x00;
    uint256 constant DECREASE_LIQUIDITY = 0x01;
    uint256 constant SWAP_EXACT_IN_SINGLE = 0x02;
    uint256 constant SWAP_EXACT_IN = 0x03;
    uint256 constant SWAP_EXACT_OUT_SINGLE = 0x04;
    uint256 constant SWAP_EXACT_OUT = 0x05;
    uint256 constant DONATE = 0x06;

    // closing deltas on the pool manager
    uint256 constant SETTLE = 0x10;
    uint256 constant SETTLE_ALL = 0x11;

    uint256 constant TAKE = 0x12;
    uint256 constant TAKE_ALL = 0x13;
    uint256 constant TAKE_PORTION = 0x14;

    uint256 constant CLOSE_CURRENCY = 0x15;
    uint256 constant CLOSE_PAIR = 0x16;
    uint256 constant CLEAR = 0x17;

    // minting/burning 6909s to close deltas
    uint256 constant MINT_6909 = 0x20;
    uint256 constant BURN_6909 = 0x21;

    // mint + burn ERC721 position
    uint256 constant MINT_POSITION = 0x22;
    uint256 constant BURN_POSITION = 0x23;
}
