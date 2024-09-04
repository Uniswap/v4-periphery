// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "./IPositionManager.sol";

/// @title Describes position NFT tokens via URI
interface IPositionDescriptor {
    /// @notice Produces the URI describing a particular token ID
    /// @dev Note this URI may be a data: URI with the JSON contents directly inlined
    /// @param positionManager The position manager for which to describe the token
    /// @param tokenId The ID of the token for which to produce a description, which may not be valid
    /// @return The URI of the ERC721-compliant metadata
    function tokenURI(IPositionManager positionManager, uint256 tokenId) external view returns (string memory);
}
