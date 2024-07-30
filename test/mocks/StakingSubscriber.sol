// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {IStakingSubscriber} from "../../src/interfaces/IStakingSubscriber.sol";
import {PositionConfig} from "../../src/libraries/PositionConfig.sol";
import {PositionManager} from "../../src/PositionManager.sol";

/// @notice A staking subscriber contract that ingests updates from the v4 position manager
contract StakingSubscriber is IStakingSubscriber {
    PositionManager posm;

    error NotAuthorizedNotifer(address sender);

    error NotImplemented();

    constructor(PositionManager _posm) {
        posm = _posm;
    }

    modifier onlyByPosm() {
        if (msg.sender != address(posm)) revert NotAuthorizedNotifer(msg.sender);
        _;
    }

    // liquidity param? in case there is already liquidity in a position that is now being staked?
    // owner is lookup able
    function notifyStake(uint256 tokenId, uint256 liquidity, PositionConfig memory config) external onlyByPosm {
        revert NotImplemented();
    }

    function notifyModifyLiquidity(uint256 tokenId, int256 liquidityChange, PositionConfig memory config)
        external
        onlyByPosm
    {
        revert NotImplemented();
    }

    function notifyTransfer(uint256 tokenId, address previousOwner, address newOwner, PositionConfig memory config)
        external
        onlyByPosm
    {
        revert NotImplemented();
    }

    function notifyUnstake(uint256 tokenId, PositionConfig memory config) external onlyByPosm {
        revert NotImplemented();
    }
}
