// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IEIP712_v4
/// @notice Interface for the EIP712 contract
interface IEIP712_v4 {
    /// @notice Returns the domain separator for the current chain.
    /// @return bytes32 The domain separator
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}
