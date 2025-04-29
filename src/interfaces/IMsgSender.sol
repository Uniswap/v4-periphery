// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IMsgSender
/// @notice Interface for contracts that expose the original caller
interface IMsgSender {
    /// @notice Returns the address of the original caller (msg.sender)
    /// @dev Uniswap v4 periphery contracts implement a callback pattern which lose
    /// the original msg.sender caller context. This view function provides a way for
    /// integrating contracts (e.g. hooks) to access the original caller address.
    /// @return The address of the original caller
    function msgSender() external view returns (address);
}
