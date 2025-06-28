// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ISubscriber} from "../interfaces/ISubscriber.sol";
import {INotifier} from "../interfaces/INotifier.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PositionInfo} from "../libraries/PositionInfoLibrary.sol";

/// @notice Notifier is used to opt in to sending updates to external contracts about position modifications or transfers
abstract contract Notifier is INotifier {
    using CustomRevert for *;

    ISubscriber private constant NO_SUBSCRIBER = ISubscriber(address(0));

    /// @notice Reentrancy guard states
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    /// @notice Current reentrancy guard state for external subscription calls
    uint256 private _notifierReentrancyStatus;

    /// @notice Thrown when a reentrant call is detected
    error NotifierReentrancyGuardReentrantCall();

    /// @inheritdoc INotifier
    uint256 public immutable unsubscribeGasLimit;

    /// @inheritdoc INotifier
    mapping(uint256 tokenId => ISubscriber subscriber) public subscriber;

    constructor(uint256 _unsubscribeGasLimit) {
        unsubscribeGasLimit = _unsubscribeGasLimit;
        _notifierReentrancyStatus = _NOT_ENTERED;
    }

    /// @notice Prevents reentrant calls to external subscription functions
    modifier notifierNonReentrant() {
        _notifierNonReentrantBefore();
        _;
        _notifierNonReentrantAfter();
    }

    /// @notice Only allow callers that are approved as spenders or operators of the tokenId
    /// @dev to be implemented by the parent contract (PositionManager)
    /// @param caller the address of the caller
    /// @param tokenId the tokenId of the position
    modifier onlyIfApproved(address caller, uint256 tokenId) virtual;

    /// @notice Enforces that the PoolManager is locked.
    modifier onlyIfPoolManagerLocked() virtual;

    function _setUnsubscribed(uint256 tokenId) internal virtual;

    function _setSubscribed(uint256 tokenId) internal virtual;

    /// @notice Internal function to set up reentrancy guard
    function _notifierNonReentrantBefore() private {
        // On the first call to nonReentrant, _status will be _NOT_ENTERED
        if (_notifierReentrancyStatus != _NOT_ENTERED) {
            revert NotifierReentrancyGuardReentrantCall();
        }

        // Any calls to nonReentrant after this point will fail
        _notifierReentrancyStatus = _ENTERED;
    }

    /// @notice Internal function to clean up reentrancy guard
    function _notifierNonReentrantAfter() private {
        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _notifierReentrancyStatus = _NOT_ENTERED;
    }

    /// @inheritdoc INotifier
    function subscribe(uint256 tokenId, address newSubscriber, bytes calldata data)
        external
        payable
        onlyIfPoolManagerLocked
        onlyIfApproved(msg.sender, tokenId)
        notifierNonReentrant
    {
        // Validate newSubscriber is not zero address
        if (newSubscriber == address(0)) revert NoCodeSubscriber.selector.revertWith();
        
        ISubscriber _subscriber = subscriber[tokenId];

        if (_subscriber != NO_SUBSCRIBER) revert AlreadySubscribed(tokenId, address(_subscriber));
        
        // Update state before external call
        _setSubscribed(tokenId);
        subscriber[tokenId] = ISubscriber(newSubscriber);

        // Make external call with reentrancy protection
        bool success = _safeCall(newSubscriber, abi.encodeCall(ISubscriber.notifySubscribe, (tokenId, data)));

        if (!success) {
            // Revert state changes if call failed
            _setUnsubscribed(tokenId);
            delete subscriber[tokenId];
            newSubscriber.bubbleUpAndRevertWith(ISubscriber.notifySubscribe.selector, SubscriptionReverted.selector);
        }

        emit Subscription(tokenId, newSubscriber);
    }

    /// @inheritdoc INotifier
    function unsubscribe(uint256 tokenId)
        external
        payable
        onlyIfPoolManagerLocked
        onlyIfApproved(msg.sender, tokenId)
        notifierNonReentrant
    {
        _unsubscribe(tokenId);
    }

    function _unsubscribe(uint256 tokenId) internal {
        ISubscriber _subscriber = subscriber[tokenId];

        if (_subscriber == NO_SUBSCRIBER) revert NotSubscribed();
        
        // Update state before external call
        _setUnsubscribed(tokenId);
        delete subscriber[tokenId];

        // Emit event before external call to ensure it's emitted even if call fails
        emit Unsubscription(tokenId, address(_subscriber));

        if (address(_subscriber).code.length > 0) {
            // require that the remaining gas is sufficient to notify the subscriber
            // otherwise, users can select a gas limit where .notifyUnsubscribe hits OutOfGas yet the
            // transaction/unsubscription can still succeed
            if (gasleft() < unsubscribeGasLimit) GasLimitTooLow.selector.revertWith();
            
            // Use try-catch to prevent subscriber from blocking unsubscription
            try _subscriber.notifyUnsubscribe{gas: unsubscribeGasLimit}(tokenId) {} catch {
                // Silently ignore failures in unsubscribe notifications
                // This prevents malicious subscribers from blocking unsubscription
            }
        }
    }

    /// @dev note this function also deletes the subscriber address from the mapping
    /// @dev This function is called from within already protected contexts, so no additional reentrancy guard
    function _removeSubscriberAndNotifyBurn(
        uint256 tokenId,
        address owner,
        PositionInfo info,
        uint256 liquidity,
        BalanceDelta feesAccrued
    ) internal {
        address _subscriber = address(subscriber[tokenId]);

        // remove the subscriber before external call
        delete subscriber[tokenId];

        bool success =
            _safeCall(_subscriber, abi.encodeCall(ISubscriber.notifyBurn, (tokenId, owner, info, liquidity, feesAccrued)));

        if (!success) {
            _subscriber.bubbleUpAndRevertWith(ISubscriber.notifyBurn.selector, BurnNotificationReverted.selector);
        }
    }

    /// @dev This function is called from within already protected contexts, so no additional reentrancy guard
    function _notifyModifyLiquidity(uint256 tokenId, int256 liquidityChange, BalanceDelta feesAccrued) internal {
        address _subscriber = address(subscriber[tokenId]);

        bool success = _safeCall(
            _subscriber, abi.encodeCall(ISubscriber.notifyModifyLiquidity, (tokenId, liquidityChange, feesAccrued))
        );

        if (!success) {
            _subscriber.bubbleUpAndRevertWith(
                ISubscriber.notifyModifyLiquidity.selector, ModifyLiquidityNotificationReverted.selector
            );
        }
    }

    /// @notice Safe external call with additional validation and reentrancy protection
    /// @param target The address to call
    /// @param encodedCall The encoded function call
    /// @return success Whether the call succeeded
    function _safeCall(address target, bytes memory encodedCall) internal returns (bool success) {
        if (target.code.length == 0) NoCodeSubscriber.selector.revertWith();
        
        // Additional validation: ensure target is not this contract to prevent self-calls
        if (target == address(this)) revert NotifierReentrancyGuardReentrantCall();
        
        // Store original reentrancy status to check for nested calls during external call
        uint256 originalStatus = _notifierReentrancyStatus;
        
        assembly ("memory-safe") {
            success := call(gas(), target, 0, add(encodedCall, 0x20), mload(encodedCall), 0, 0)
        }
        
        // Verify that the external call didn't cause a reentrant call that changed our status
        if (_notifierReentrancyStatus != originalStatus) {
            revert NotifierReentrancyGuardReentrantCall();
        }
    }

    /// @notice Legacy _call function for backward compatibility - now uses _safeCall
    /// @dev This function is deprecated and should not be used in new code
    function _call(address target, bytes memory encodedCall) internal returns (bool success) {
        return _safeCall(target, encodedCall);
    }
}
