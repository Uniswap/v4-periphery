// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IUnorderedNonce} from "../interfaces/IUnorderedNonce.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

/// @title Unordered Nonce
/// @notice Contract state and methods for using unordered nonces in signatures
contract UnorderedNonce is IUnorderedNonce {
    using CustomRevert for bytes4;

    /// @inheritdoc IUnorderedNonce
    mapping(address owner => mapping(uint256 word => uint256 bitmap)) public nonces;
    
    /// @dev Rate limiting: track last revocation time per address
    mapping(address => uint256) public lastRevocationTime;
    /// @dev Minimum time between revocations per address (prevents spam)
    uint256 public constant REVOCATION_COOLDOWN = 30; // 30 seconds
    
    /// @notice Thrown when trying to revoke nonces too frequently
    error RevocationTooFrequent(address sender, uint256 lastTime, uint256 currentTime);

    /// @notice Consume a nonce, reverting if it has already been used
    /// @param owner address, the owner/signer of the nonce
    /// @param nonce uint256, the nonce to consume. The top 248 bits are the word, the bottom 8 bits indicate the bit position
    function _useUnorderedNonce(address owner, uint256 nonce) internal {
        uint256 wordPos = nonce >> 8;
        uint256 bitPos = uint8(nonce);

        uint256 bit = 1 << bitPos;
        uint256 flipped = nonces[owner][wordPos] ^= bit;
        if (flipped & bit == 0) NonceAlreadyUsed.selector.revertWith();
    }

    /// @inheritdoc IUnorderedNonce
    function revokeNonce(uint256 nonce) external payable {
        // Add rate limiting to prevent spam attacks
        uint256 lastTime = lastRevocationTime[msg.sender];
        if (lastTime != 0 && block.timestamp - lastTime < REVOCATION_COOLDOWN) {
            RevocationTooFrequent.selector.revertWith(msg.sender, lastTime, block.timestamp);
        }
        lastRevocationTime[msg.sender] = block.timestamp;
        
        _useUnorderedNonce(msg.sender, nonce);
    }
}
