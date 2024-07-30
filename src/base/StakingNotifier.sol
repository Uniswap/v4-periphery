// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {IStakingSubscriber} from "../interfaces/IStakingSubscriber.sol";
import {PositionConfig} from "../libraries/PositionConfig.sol";

struct StakingConfig {
    IStakingSubscriber subscriber;
}

contract StakingNotifier {
    error StakingSubscriberCannotBeNotified();

    event Staked(uint256 tokenId, address subscriber);

    uint256 private immutable stakingGasLimit;
    IStakingSubscriber private constant NO_STAKING_SUBSCRIBER = IStakingSubscriber(address(0));

    mapping(uint256 tokenId => StakingConfig config) public stakingConfig;

    constructor(uint256 _stakingGasLimit) {
        stakingGasLimit = _stakingGasLimit;
    }

    function _notifyModifyLiquidity(uint256 tokenId, int256 liquidityChange, PositionConfig memory config) internal {
        IStakingSubscriber subscriber = stakingConfig[tokenId].subscriber;
        if (subscriber != NO_STAKING_SUBSCRIBER) {
            if (gasleft() < stakingGasLimit) revert StakingSubscriberCannotBeNotified();
            subscriber.notifyModifyLiquidity{gas: stakingGasLimit}(tokenId, liquidityChange, config);
        }
    }

    function _notifyStake(uint256 tokenId, StakingConfig memory _stakingConfig, PositionConfig memory config)
        internal
    {
        stakingConfig[tokenId] = _stakingConfig;
        _stakingConfig.subscriber.notifyStake(tokenId, 0, config);
        emit Staked(tokenId, address(_stakingConfig.subscriber));
    }

    // TODO
    // on transfer, notify subscriber. do we need to reset staking permissions?
    // on stake, pass through position currenct liq?
    // support unstake functionality
    // support hooks auto-enrolling positions in their staking program
    // use percentage/fraction for gasLimit
    // other gasLimit concerns?
    // can we optimize in the no stake case (reduce from 1 SLOAD :/)
}
