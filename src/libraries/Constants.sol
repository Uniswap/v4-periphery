// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.19;

library Constants {
    /// @notice used to signal that an action should use the input value of the open delta on the pool manager
    /// or of the balance that the contract holds
    uint128 internal constant CONTRACT_BALANCE = 0;
    uint128 internal constant OPEN_DELTA = 1;

    /// @notice used to signal that the recipient of an action should be the _msgSender of address(this)
    address internal constant MSG_SENDER = address(1);
    address internal constant ADDRESS_THIS = address(2);
}
