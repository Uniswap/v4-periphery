// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IMsgSender
/// @notice Interface for contracts that expose the original msg.sender
interface IMsgSender {
    function msgSender() external view returns (address);
}
