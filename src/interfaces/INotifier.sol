// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {PositionConfig} from "../libraries/PositionConfig.sol";

/// @notice This interface is used to opt in to sending updates to external contracts about position modifications or transfers
interface INotifier {
    /// @notice Enables the subscriber to receive notifications for a respective position
    /// @param tokenId the ERC721 tokenId
    /// @param config the corresponding PositionConfig for the tokenId
    /// @param subscriber the address to notify
    function subscribe(uint256 tokenId, PositionConfig calldata config, address subscriber) external;

    /// @notice Removes the subscriber from receiving notifications for a respective position
    /// @param tokenId the ERC721 tokenId
    /// @param config the corresponding PositionConfig for the tokenId
    function unsubscribe(uint256 tokenId, PositionConfig calldata config) external;
}
