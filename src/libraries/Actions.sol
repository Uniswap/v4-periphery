// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

/// @notice Library to define different pool actions.
library Actions {
    // TODO can explore having these as an enum but i think constants might be cheaper

    uint256 constant SWAP = 0x00;
    uint256 constant INCREASE_LIQUIDITY = 0x01;
    uint256 constant DECREASE_LIQUIDITY = 0x01;
    uint256 constant DONATE = 0x03;
    uint256 constant CLEAR_DELTA = 0x04;
    uint256 constant SETTLE = 0x05;
    uint256 constant TAKE = 0x06;
    uint256 constant MINT_6909 = 0x07;
    uint256 constant BURN_6909 = 0x08;
}
