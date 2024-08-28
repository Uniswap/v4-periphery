// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IEIP712_v4 {
    /// @notice The EIP-712 domain separator for the current chain
    /// @return bytes32 The domain separator
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}
