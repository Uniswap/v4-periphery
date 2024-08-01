// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {ISubscriber} from "../interfaces/ISubscriber.sol";
import {PositionConfig} from "../libraries/PositionConfig.sol";
import {GasLimitCalculator} from "../libraries/GasLimitCalculator.sol";

import "forge-std/console2.sol";

contract Notifier {
    using GasLimitCalculator for uint256;

    error SubscriberCannotBeNotified();
    error AlreadySubscribed(address subscriber);

    event Subscribed(uint256 tokenId, address subscriber);
    event Unsubscribed(uint256 tokenId, address subscriber);

    ISubscriber private constant NO_SUBSCRIBER = ISubscriber(address(0));

    // a percentage of the block.gaslimit denoted in BPS, used as the gas limit for subscriber calls
    // 100 bps is 1%
    // at 30M gas, the limit is 300K
    uint256 private constant BLOCK_LIMIT_BPS = 100;

    mapping(uint256 tokenId => ISubscriber subscriber) public subscriber;

    constructor() {}

    function _subscribe(uint256 tokenId, PositionConfig memory config, address newSubscriber) internal {
        ISubscriber _subscriber = subscriber[tokenId];

        if (_subscriber != NO_SUBSCRIBER) revert AlreadySubscribed(address(_subscriber));
        subscriber[tokenId] = ISubscriber(newSubscriber);

        ISubscriber(newSubscriber).notifySubscribe(tokenId, config);
        emit Subscribed(tokenId, address(newSubscriber));
    }

    /// @dev Must always allow a user to unsubscribe. In the case of a malicious subscriber, a user can always unsubscribe safely, ensuring liquidity is always modifiable.
    function _unsubscribe(uint256 tokenId, PositionConfig memory config) internal {
        ISubscriber _subscriber = subscriber[tokenId];

        uint256 subscriberGasLimit = BLOCK_LIMIT_BPS.toGasLimit();

        bytes memory data = abi.encodeWithSelector(ISubscriber.notifyUnsubscribe.selector, tokenId, config);

        //try _subscriber.notifyUnsubscribe{gas: subscriberGasLimit}(tokenId, config) {} catch {}
        assembly ("memory-safe") {
            pop(call(subscriberGasLimit, _subscriber, 0, add(data, 0x20), mload(data), 0, 0))
        }

        delete subscriber[tokenId];
        emit Unsubscribed(tokenId, address(_subscriber));
    }

    function _notifyModifyLiquidity(uint256 tokenId, PositionConfig memory config, int256 liquidityChange) internal {
        subscriber[tokenId].notifyModifyLiquidity(tokenId, config, liquidityChange);
    }

    function _notifyTransfer(uint256 tokenId, address previousOwner, address newOwner) internal {
        subscriber[tokenId].notifyTransfer(tokenId, previousOwner, newOwner);
    }
}
