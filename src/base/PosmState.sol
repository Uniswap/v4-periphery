// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ERC721Permit_v4} from "./ERC721Permit_v4.sol";
import {PositionConfig, PositionConfigLibrary} from "../libraries/PositionConfig.sol";

contract PosmState is ERC721Permit_v4 {
    using PositionConfigLibrary for *;

    /// @dev The ID of the next token that will be minted. Skips 0
    uint256 public _nextTokenId = 1;

    mapping(uint256 tokenId => bytes32 config) internal positionConfigs;

    constructor() ERC721Permit_v4("Uniswap V4 Positions NFT", "UNI-V4-POSM") {}

    /// @notice Reverts if the deadline has passed
    /// @param deadline The timestamp at which the call is no longer valid, passed in by the caller
    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert();// TODO: error DeadlinePassed();
        _;
    }

    /// @notice Reverts if the caller is not the owner or approved for the ERC721 token
    /// @param caller The address of the caller
    /// @param tokenId the unique identifier of the ERC721 token
    /// @dev either msg.sender or _msgSender() is passed in as the caller
    /// _msgSender() should ONLY be used if this is being called from within the unlockCallback
    modifier onlyIfApproved(address caller, uint256 tokenId) {
        if (!_isApprovedOrOwner(caller, tokenId)) revert(); // TODO: NotApproved(caller);
        _;
    }

    /// @notice Reverts if the hash of the config does not equal the saved hash
    /// @param tokenId the unique identifier of the ERC721 token
    /// @param config the PositionConfig to check against
    modifier onlyValidConfig(uint256 tokenId, PositionConfig calldata config) {
        if (positionConfigs.getConfigId(tokenId) != config.toId()) revert(); // TODO: IncorrectPositionConfigForTokenId(tokenId);
        _;
    }
}
