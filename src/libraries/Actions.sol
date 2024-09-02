// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

/// @notice Library to define different pool actions.
/// @dev These are suggested common commands, however additional commands should be defined as required
library Actions {
    // pool actions
    // liquidity actions
    uint256 constant INCREASE_LIQUIDITY = 0x00;
    uint256 constant DECREASE_LIQUIDITY = 0x01;
    uint256 constant MINT_POSITION = 0x02;
    uint256 constant BURN_POSITION = 0x03;
    // swapping
    uint256 constant SWAP_EXACT_IN_SINGLE = 0x04;
    uint256 constant SWAP_EXACT_IN = 0x05;
    uint256 constant SWAP_EXACT_OUT_SINGLE = 0x06;
    uint256 constant SWAP_EXACT_OUT = 0x07;
    // donate
    uint256 constant DONATE = 0x08;

    // closing deltas on the pool manager
    // settling
    uint256 constant SETTLE = 0x09;
    uint256 constant SETTLE_ALL = 0x10;
    uint256 constant SETTLE_PAIR = 0x11;
    // taking
    uint256 constant TAKE = 0x12;
    uint256 constant TAKE_ALL = 0x13;
    uint256 constant TAKE_PORTION = 0x14;
    uint256 constant TAKE_PAIR = 0x15;

    uint256 constant SETTLE_TAKE_PAIR = 0x16;
    uint256 constant CLOSE_CURRENCY = 0x17;
    uint256 constant CLEAR_OR_TAKE = 0x18;
    uint256 constant SWEEP = 0x19;

    // minting/burning 6909s to close deltas
    uint256 constant MINT_6909 = 0x20;
    uint256 constant BURN_6909 = 0x21;
}
