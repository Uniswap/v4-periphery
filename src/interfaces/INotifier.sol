// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {PositionConfig} from "../libraries/PositionConfig.sol";
import {ISubscriber} from "./ISubscriber.sol";

/// @notice This interface is used to opt in to sending updates to external contracts about position modifications or transfers
interface INotifier {
    /// @notice Wraps the revert message of the subscriber contract on a reverting subscription
    error Wrap__SubscriptionReverted(address subscriber, bytes reason);
    /// @notice Wraps the revert message of the subscriber contract on a reverting modify liquidity notification
    error Wrap__ModifyLiquidityNotificationReverted(address subscriber, bytes reason);
    /// @notice Wraps the revert message of the subscriber contract on a reverting transfer notification
    error Wrap__TransferNotificationReverted(address subscriber, bytes reason);

    /// @notice Returns the subscriber for a respective position
    /// @param tokenId the ERC721 tokenId
    /// @return subscriber the subscriber contract
    function subscriber(uint256 tokenId) external view returns (ISubscriber subscriber);

    /// @notice Enables the subscriber to receive notifications for a respective position
    /// @param tokenId the ERC721 tokenId
    /// @param config the corresponding PositionConfig for the tokenId
    /// @param newSubscriber the address of the subscriber contract
    /// @param data caller-provided data that's forwarded to the subscriber contract
    /// @dev Calling subscribe when a position is already subscribed will revert
    /// @dev payable so it can be multicalled with NATIVE related actions
    function subscribe(uint256 tokenId, PositionConfig calldata config, address newSubscriber, bytes calldata data)
        external
        payable;

    /// @notice Removes the subscriber from receiving notifications for a respective position
    /// @param tokenId the ERC721 tokenId
    /// @param config the corresponding PositionConfig for the tokenId
    /// @dev payable so it can be multicalled with NATIVE related actions
    /// @dev Must always allow a user to unsubscribe. In the case of a malicious subscriber, a user can always unsubscribe safely, ensuring liquidity is always modifiable.
    function unsubscribe(uint256 tokenId, PositionConfig calldata config) external payable;

    /// @notice Returns whether a position should call out to notify a subscribing contract on modification or transfer
    /// @param tokenId the ERC721 tokenId
    /// @return bool whether or not the position has a subscriber
    function hasSubscriber(uint256 tokenId) external view returns (bool);
}
