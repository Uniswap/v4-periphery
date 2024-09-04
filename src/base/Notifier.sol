// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import {ISubscriber} from "../interfaces/ISubscriber.sol";
import {PositionConfig} from "../libraries/PositionConfig.sol";
import {PositionConfigId, PositionConfigIdLibrary} from "../libraries/PositionConfigId.sol";
import {INotifier} from "../interfaces/INotifier.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @notice Notifier is used to opt in to sending updates to external contracts about position modifications or transfers
abstract contract Notifier is INotifier {
    using CustomRevert for bytes4;
    using PositionConfigIdLibrary for PositionConfigId;

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

    /// @notice Only allow callers that provide the correct config for the tokenId
    /// @dev to be implemented by the parent contract (PositionManager)
    /// @param tokenId the tokenId of the position
    /// @param config the config of the tokenId
    modifier onlyValidConfig(uint256 tokenId, PositionConfig calldata config) virtual;

    function _positionConfigs(uint256 tokenId) internal view virtual returns (PositionConfigId storage);

    /// @inheritdoc INotifier
    function subscribe(uint256 tokenId, PositionConfig calldata config, address newSubscriber, bytes calldata data)
        external
        payable
        onlyIfApproved(msg.sender, tokenId)
        onlyValidConfig(tokenId, config)
    {
        // will revert below if the user already has a subscriber
        _positionConfigs(tokenId).setSubscribe();
        ISubscriber _subscriber = subscriber[tokenId];

        if (_subscriber != NO_SUBSCRIBER) revert AlreadySubscribed(tokenId, address(_subscriber));
        subscriber[tokenId] = ISubscriber(newSubscriber);

        bool success = _call(newSubscriber, abi.encodeCall(ISubscriber.notifySubscribe, (tokenId, config, data)));

        if (!success) {
            Wrap__SubscriptionReverted.selector.bubbleUpAndRevertWith(newSubscriber);
        }

        emit Subscription(tokenId, newSubscriber);
    }

    /// @inheritdoc INotifier
    function unsubscribe(uint256 tokenId, PositionConfig calldata config)
        external
        payable
        onlyIfApproved(msg.sender, tokenId)
        onlyValidConfig(tokenId, config)
    {
        if (!_positionConfigs(tokenId).hasSubscriber()) NotSubscribed.selector.revertWith();
        _unsubscribe(tokenId, config);
    }

    function _unsubscribe(uint256 tokenId, PositionConfig calldata config) internal {
        _positionConfigs(tokenId).setUnsubscribe();
        ISubscriber _subscriber = subscriber[tokenId];

        delete subscriber[tokenId];

        if (address(_subscriber).code.length > 0) {
            // require that the remaining gas is sufficient to notify the subscriber
            // otherwise, users can select a gas limit where .notifyUnsubscribe hits OutOfGas yet the
            // transaction/unsubscription can still succeed
            if (gasleft() < unsubscribeGasLimit) GasLimitTooLow.selector.revertWith();
            try _subscriber.notifyUnsubscribe{gas: unsubscribeGasLimit}(tokenId, config) {} catch {}
        }

        emit Unsubscription(tokenId, address(_subscriber));
    }

    function _notifyModifyLiquidity(
        uint256 tokenId,
        PositionConfig memory config,
        int256 liquidityChange,
        BalanceDelta feesAccrued
    ) internal {
        ISubscriber _subscriber = subscriber[tokenId];

        bool success = _call(
            address(_subscriber),
            abi.encodeCall(ISubscriber.notifyModifyLiquidity, (tokenId, config, liquidityChange, feesAccrued))
        );

        if (!success) {
            Wrap__ModifyLiquidityNotificationReverted.selector.bubbleUpAndRevertWith(address(_subscriber));
        }
    }

    function _notifyTransfer(uint256 tokenId, address previousOwner, address newOwner) internal {
        ISubscriber _subscriber = subscriber[tokenId];

        bool success =
            _call(address(_subscriber), abi.encodeCall(ISubscriber.notifyTransfer, (tokenId, previousOwner, newOwner)));

        if (!success) {
            Wrap__TransferNotificationReverted.selector.bubbleUpAndRevertWith(address(_subscriber));
        }
    }

    function _call(address target, bytes memory encodedCall) internal returns (bool success) {
        if (target.code.length == 0) NoCodeSubscriber.selector.revertWith();
        assembly ("memory-safe") {
            success := call(gas(), target, 0, add(encodedCall, 0x20), mload(encodedCall), 0, 0)
        }
    }

    /// @inheritdoc INotifier
    function hasSubscriber(uint256 tokenId) external view returns (bool) {
        return _positionConfigs(tokenId).hasSubscriber();
    }
}
