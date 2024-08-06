// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {PositionConfig, PositionConfigLibrary} from "../libraries/PositionConfig.sol";

abstract contract PosmSharedState {
    using PositionConfigLibrary for *;

    mapping(uint256 tokenId => bytes32 config) internal positionConfigs;

    /// @notice Reverts if the caller is not the owner or approved for the ERC721 token
    /// @param caller The address of the caller
    /// @param tokenId the unique identifier of the ERC721 token
    /// @dev either msg.sender or _msgSender() is passed in as the caller
    /// _msgSender() should ONLY be used if this is being called from within the unlockCallback
    modifier onlyIfApproved(address caller, uint256 tokenId) virtual;

    function getPositionConfigId(uint256 tokenId) external view returns (bytes32) {
        return positionConfigs.getConfigId(tokenId);
    }

    /// @notice Reverts if the hash of the config does not equal the saved hash
    /// @param tokenId the unique identifier of the ERC721 token
    /// @param config the PositionConfig to check against
    modifier onlyValidConfig(uint256 tokenId, PositionConfig calldata config) {
        if (positionConfigs.getConfigId(tokenId) != config.toId()) revert(); // TODO: IncorrectPositionConfigForTokenId(tokenId);
        _;
    }
}
