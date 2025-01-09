// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title Action Constants
/// @notice Common constants used in actions
/// @dev Constants are gas efficient alternatives to their literal values
library ActionConstants {
    /// @notice used to signal that an action should use the input value of the open delta on the pool manager
    /// or of the balance that the contract holds
    uint128 internal constant OPEN_DELTA = 0;
    /// @notice used to signal that an action should use the contract's entire balance of a currency
    /// This value is equivalent to 1<<255, i.e. a singular 1 in the most significant bit.
    uint256 internal constant CONTRACT_BALANCE = 0x8000000000000000000000000000000000000000000000000000000000000000;

    /// @notice used to signal that the recipient of an action should be the msgSender
    address internal constant MSG_SENDER = address(1);

    /// @notice used to signal that the recipient of an action should be the address(this)
    address internal constant ADDRESS_THIS = address(2);
}
