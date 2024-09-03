// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @title Multicall_v4 interface
/// @notice Enables calling multiple methods in a single call to the contract
interface IMulticall_v4 {
    /// @notice Call multiple functions in the current contract and return the data from all of them if they all succeed
    /// @dev The `msg.value` is passed onto all subcalls, even if a previous subcall has consumed the ether.
    /// Subcalls can instead use `address(this).value` to see the available ETH, and consume it using {value: x}.
    /// @param data The encoded function data for each of the calls to make to this contract
    /// @return results The results from each of the calls passed in via data
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results);
}
