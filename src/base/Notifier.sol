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

    /// @inheritdoc INotifier
    uint256 public immutable unsubscribeGasLimit;

    /// @inheritdoc INotifier
    mapping(uint256 tokenId => ISubscriber subscriber) public subscriber;

    constructor(uint256 _unsubscribeGasLimit) {
        unsubscribeGasLimit = _unsubscribeGasLimit;
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

    /// @inheritdoc INotifier
    function subscribe(uint256 tokenId, address newSubscriber, bytes calldata data)
        external
        payable
        onlyIfPoolManagerLocked
        onlyIfApproved(msg.sender, tokenId)
    {
        ISubscriber _subscriber = subscriber[tokenId];

        if (_subscriber != NO_SUBSCRIBER) revert AlreadySubscribed(tokenId, address(_subscriber));
        _setSubscribed(tokenId);

        subscriber[tokenId] = ISubscriber(newSubscriber);

        bool success = _call(newSubscriber, abi.encodeCall(ISubscriber.notifySubscribe, (tokenId, data)));

        if (!success) {
            newSubscriber.bubbleUpAndRevertWith(ISubscriber.notifySubscribe.selector, SubscriptionReverted.selector);
        }

        emit Subscription(tokenId, newSubscriber);
    }

    /// @inheritdoc INotifier
    function unsubscribe(uint256 tokenId) external payable onlyIfPoolManagerLocked onlyIfApproved(msg.sender, tokenId) {
        _unsubscribe(tokenId);
    }

    function _unsubscribe(uint256 tokenId) internal {
        ISubscriber _subscriber = subscriber[tokenId];

        if (_subscriber == NO_SUBSCRIBER) revert NotSubscribed();
        _setUnsubscribed(tokenId);

        delete subscriber[tokenId];

        if (address(_subscriber).code.length > 0) {
            // require that the remaining gas is sufficient to notify the subscriber
            // otherwise, users can select a gas limit where .notifyUnsubscribe hits OutOfGas yet the
            // transaction/unsubscription can still succeed
            if (gasleft() < unsubscribeGasLimit) GasLimitTooLow.selector.revertWith();
            try _subscriber.notifyUnsubscribe{gas: unsubscribeGasLimit}(tokenId) {} catch {}
        }

        emit Unsubscription(tokenId, address(_subscriber));
    }

    /// @dev note this function also deletes the subscriber address from the mapping
    function _removeSubscriberAndNotifyBurn(
        uint256 tokenId,
        address owner,
        PositionInfo info,
        uint256 liquidity,
        BalanceDelta feesAccrued
    ) internal {
        address _subscriber = address(subscriber[tokenId]);

        // remove the subscriber
        delete subscriber[tokenId];

        bool success =
            _call(_subscriber, abi.encodeCall(ISubscriber.notifyBurn, (tokenId, owner, info, liquidity, feesAccrued)));

        if (!success) {
            _subscriber.bubbleUpAndRevertWith(ISubscriber.notifyBurn.selector, BurnNotificationReverted.selector);
        }
    }

    function _notifyModifyLiquidity(uint256 tokenId, int256 liquidityChange, BalanceDelta feesAccrued) internal {
        address _subscriber = address(subscriber[tokenId]);

        bool success = _call(
            _subscriber, abi.encodeCall(ISubscriber.notifyModifyLiquidity, (tokenId, liquidityChange, feesAccrued))
        );

        if (!success) {
            _subscriber.bubbleUpAndRevertWith(
                ISubscriber.notifyModifyLiquidity.selector, ModifyLiquidityNotificationReverted.selector
            );
        }
    }

    function _call(address target, bytes memory encodedCall) internal returns (bool success) {
        if (target.code.length == 0) NoCodeSubscriber.selector.revertWith();
        assembly ("memory-safe") {
            success := call(gas(), target, 0, add(encodedCall, 0x20), mload(encodedCall), 0, 0)
        }
    }
}
