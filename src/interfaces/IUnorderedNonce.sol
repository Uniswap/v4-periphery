// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IUnorderedNonce
/// @notice Interface for the UnorderedNonce contract
interface IUnorderedNonce {
    error NonceAlreadyUsed();

    /// @notice mapping of nonces consumed by each address, where a nonce is a single bit on the 256-bit bitmap
    /// @dev word is at most type(uint248).max
    function nonces(address owner, uint256 word) external view returns (uint256);

    /// @notice Revoke a nonce by spending it, preventing it from being used again
    /// @dev Used in cases where a valid nonce has not been broadcasted onchain, and the owner wants to revoke the validity of the nonce
    /// @dev payable so it can be multicalled with native-token related actions
    function revokeNonce(uint256 nonce) external payable;
}
