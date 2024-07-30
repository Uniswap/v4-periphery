// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/// @title Signature Verification Library
/// @notice A library to verify signatures
library SignatureVerification {
    /// @notice Thrown when the recovered signer is equal to the zero address
    error InvalidSignature();

    /// @notice Thrown when the recovered signer does not equal the claimedSigner
    error InvalidSigner();

    /// @notice Thrown when the recovered contract signature is incorrect
    error InvalidContractSignature();

    function verify(uint8 v, bytes32 r, bytes32 s, bytes32 hash, address claimedSigner) internal view {
        if (claimedSigner.code.length == 0) {
            address signer = ecrecover(hash, v, r, s);
            if (signer == address(0)) revert InvalidSignature();
            if (signer != claimedSigner) revert InvalidSigner();
        } else {
            bytes4 magicValue = IERC1271(claimedSigner).isValidSignature(hash, abi.encodePacked(r, s, v));
            if (magicValue != IERC1271.isValidSignature.selector) revert InvalidContractSignature();
        }
    }
}
