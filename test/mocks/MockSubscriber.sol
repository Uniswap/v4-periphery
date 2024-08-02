// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {ISubscriber} from "../../src/interfaces/ISubscriber.sol";
import {PositionConfig} from "../../src/libraries/PositionConfig.sol";
import {PositionManager} from "../../src/PositionManager.sol";

/// @notice A subscriber contract that ingests updates from the v4 position manager
contract MockSubscriber is ISubscriber {
    PositionManager posm;

    uint256 public notifySubscribeCount;
    uint256 public notifyUnsubscribeCount;
    uint256 public notifyModifyLiquidityCount;
    uint256 public notifyTransferCount;

    error NotAuthorizedNotifer(address sender);

    error NotImplemented();

    constructor(PositionManager _posm) {
        posm = _posm;
    }

    modifier onlyByPosm() {
        if (msg.sender != address(posm)) revert NotAuthorizedNotifer(msg.sender);
        _;
    }

    function notifySubscribe(uint256 tokenId, PositionConfig memory config) external onlyByPosm {
        notifySubscribeCount++;
    }

    function notifyUnsubscribe(uint256 tokenId, PositionConfig memory config) external onlyByPosm {
        notifyUnsubscribeCount++;
    }

    function notifyModifyLiquidity(uint256 tokenId, PositionConfig memory config, int256 liquidityChange)
        external
        onlyByPosm
    {
        notifyModifyLiquidityCount++;
    }

    function notifyTransfer(uint256 tokenId, address previousOwner, address newOwner) external onlyByPosm {
        notifyTransferCount++;
    }
}
