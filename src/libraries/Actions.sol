// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

/// @notice Library to define different pool actions.
// By making these constants, and not an enum, integrators who wish to extend these actions
// can add their own additional actions where desired
library Actions {
    // Actions on a pool
    uint256 constant SWAP = 0x00;
    uint256 constant INCREASE_LIQUIDITY = 0x01;
    uint256 constant DECREASE_LIQUIDITY = 0x02;
    uint256 constant MINT_POSITION = 0x03;
    uint256 constant BURN_POSITION = 0x04;
    uint256 constant DONATE = 0x05;
    uint256 constant SWEEP_ETH = 0x06;

    // Settling deltas
    uint256 constant SETTLE = 0x10;
    uint256 constant TAKE = 0x11;
    uint256 constant MINT_6909 = 0x12;
    uint256 constant BURN_6909 = 0x13;
    uint256 constant CLEAR_DELTA = 0x14;
}
