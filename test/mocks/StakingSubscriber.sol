// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {ISubscriber} from "../../src/interfaces/ISubscriber.sol";
import {PositionConfig} from "../../src/libraries/PositionConfig.sol";
import {PositionManager} from "../../src/PositionManager.sol";

/// @notice A staking subscriber contract that ingests updates from the v4 position manager
contract StakingSubscriber is ISubscriber {
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

    function notifySubscribe(uint256 tokenId, PositionConfig memory config) external view onlyByPosm {
        revert NotImplemented();
    }

    function notifyUnsubscribe(uint256 tokenId, PositionConfig memory config) external view onlyByPosm {
        revert NotImplemented();
    }

    function notifyModifyLiquidity(uint256 tokenId, PositionConfig memory config, int256 liquidityChange)
        external
        view
        onlyByPosm
    {
        revert NotImplemented();
    }

    function notifyTransfer(uint256 tokenId, PositionConfig memory config, address previousOwner, address newOwner)
        external
        view
        onlyByPosm
    {
        revert NotImplemented();
    }
}
