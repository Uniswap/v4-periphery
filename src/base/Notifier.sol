// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {ISubscriber} from "../interfaces/ISubscriber.sol";
import {PositionConfig} from "../libraries/PositionConfig.sol";
import {BipsLibrary} from "../libraries/BipsLibrary.sol";
import {INotifier, PositionConfig} from "../interfaces/INotifier.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

/// @notice Notifier is used to opt in to sending updates to external contracts about position modifications or transfers
abstract contract Notifier is INotifier {
    using BipsLibrary for uint256;
    using CustomRevert for bytes4;

    error AlreadySubscribed(address subscriber);

    event Subscribed(uint256 tokenId, address subscriber);
    event Unsubscribed(uint256 tokenId, address subscriber);

    ISubscriber private constant NO_SUBSCRIBER = ISubscriber(address(0));

    // a percentage of the block.gaslimit denoted in BPS, used as the gas limit for subscriber calls
    // 100 bps is 1%
    // at 30M gas, the limit is 300K
    uint256 private constant BLOCK_LIMIT_BPS = 100;

    mapping(uint256 tokenId => ISubscriber subscriber) public subscriber;

    function _subscribe(uint256 tokenId, PositionConfig memory config, address newSubscriber, bytes memory data)
        internal
    {
        ISubscriber _subscriber = subscriber[tokenId];

        if (_subscriber != NO_SUBSCRIBER) revert AlreadySubscribed(address(_subscriber));
        subscriber[tokenId] = ISubscriber(newSubscriber);

        try ISubscriber(newSubscriber).notifySubscribe(tokenId, config, data) {}
        catch (bytes memory reason) {
            revert Wrap__SubsciptionReverted(newSubscriber, reason);
        }
        emit Subscribed(tokenId, address(newSubscriber));
    }

    /// @dev Must always allow a user to unsubscribe. In the case of a malicious subscriber, a user can always unsubscribe safely, ensuring liquidity is always modifiable.
    function _unsubscribe(uint256 tokenId, PositionConfig memory config, bytes memory data) internal {
        ISubscriber _subscriber = subscriber[tokenId];

        uint256 subscriberGasLimit = block.gaslimit.calculatePortion(BLOCK_LIMIT_BPS);

        try _subscriber.notifyUnsubscribe{gas: subscriberGasLimit}(tokenId, config, data) {} catch {}

        delete subscriber[tokenId];
        emit Unsubscribed(tokenId, address(_subscriber));
    }

    function _notifyModifyLiquidity(uint256 tokenId, PositionConfig memory config, int256 liquidityChange) internal {
        ISubscriber subscriber_ = subscriber[tokenId];
        try subscriber_.notifyModifyLiquidity(tokenId, config, liquidityChange) {}
        catch (bytes memory reason) {
            revert Wrap__ModifyLiquidityNotificationReverted(address(subscriber_), reason);
        }
    }

    function _notifyTransfer(uint256 tokenId, address previousOwner, address newOwner) internal {
        ISubscriber subscriber_ = subscriber[tokenId];
        try subscriber_.notifyTransfer(tokenId, previousOwner, newOwner) {}
        catch (bytes memory reason) {
            revert Wrap__TransferNotificationReverted(address(subscriber_), reason);
        }
    }
}
