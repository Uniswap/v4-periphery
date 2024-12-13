// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ISubscriber} from "./ISubscriber.sol";

/// @title INotifier
/// @notice Interface for the Notifier contract
interface INotifier {
    /// @notice Thrown when unsubscribing without a subscriber
    error NotSubscribed();
    /// @notice Thrown when a subscriber does not have code
    error NoCodeSubscriber();
    /// @notice Thrown when a user specifies a gas limit too low to avoid valid unsubscribe notifications
    error GasLimitTooLow();
    /// @notice Wraps the revert message of the subscriber contract on a reverting subscription
    error SubscriptionReverted(address subscriber, bytes reason);
    /// @notice Wraps the revert message of the subscriber contract on a reverting modify liquidity notification
    error ModifyLiquidityNotificationReverted(address subscriber, bytes reason);
    /// @notice Wraps the revert message of the subscriber contract on a reverting burn notification
    error BurnNotificationReverted(address subscriber, bytes reason);
    /// @notice Thrown when a tokenId already has a subscriber
    error AlreadySubscribed(uint256 tokenId, address subscriber);

    /// @notice Emitted on a successful call to subscribe
    event Subscription(uint256 indexed tokenId, address indexed subscriber);
    /// @notice Emitted on a successful call to unsubscribe
    event Unsubscription(uint256 indexed tokenId, address indexed subscriber);

    /// @notice Returns the subscriber for a respective position
    /// @param tokenId the ERC721 tokenId
    /// @return subscriber the subscriber contract
    function subscriber(uint256 tokenId) external view returns (ISubscriber subscriber);

    /// @notice Enables the subscriber to receive notifications for a respective position
    /// @param tokenId the ERC721 tokenId
    /// @param newSubscriber the address of the subscriber contract
    /// @param data caller-provided data that's forwarded to the subscriber contract
    /// @dev Calling subscribe when a position is already subscribed will revert
    /// @dev payable so it can be multicalled with NATIVE related actions
    /// @dev will revert if pool manager is locked
    function subscribe(uint256 tokenId, address newSubscriber, bytes calldata data) external payable;

    /// @notice Removes the subscriber from receiving notifications for a respective position
    /// @param tokenId the ERC721 tokenId
    /// @dev Callers must specify a high gas limit (remaining gas should be higher than unsubscriberGasLimit) such that the subscriber can be notified
    /// @dev payable so it can be multicalled with NATIVE related actions
    /// @dev Must always allow a user to unsubscribe. In the case of a malicious subscriber, a user can always unsubscribe safely, ensuring liquidity is always modifiable.
    /// @dev will revert if pool manager is locked
    function unsubscribe(uint256 tokenId) external payable;

    /// @notice Returns and determines the maximum allowable gas-used for notifying unsubscribe
    /// @return uint256 the maximum gas limit when notifying a subscriber's `notifyUnsubscribe` function
    function unsubscribeGasLimit() external view returns (uint256);
}
