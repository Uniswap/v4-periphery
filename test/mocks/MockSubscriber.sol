// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {ISubscriber} from "../../src/interfaces/ISubscriber.sol";
import {PositionManager} from "../../src/PositionManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @notice A subscriber contract that ingests updates from the v4 position manager
contract MockSubscriber is ISubscriber {
    PositionManager posm;

    uint256 public notifySubscribeCount;
    uint256 public notifyUnsubscribeCount;
    uint256 public notifyModifyLiquidityCount;
    uint256 public notifyTransferCount;
    int256 public liquidityChange;
    BalanceDelta public feesAccrued;

    bytes public subscribeData;

    error NotAuthorizedNotifer(address sender);

    error NotImplemented();

    constructor(PositionManager _posm) {
        posm = _posm;
    }

    modifier onlyByPosm() {
        if (msg.sender != address(posm)) revert NotAuthorizedNotifer(msg.sender);
        _;
    }

    function notifySubscribe(uint256, bytes memory data) external onlyByPosm {
        notifySubscribeCount++;
        subscribeData = data;
    }

    function notifyUnsubscribe(uint256) external onlyByPosm {
        notifyUnsubscribeCount++;
    }

    function notifyModifyLiquidity(uint256, int256 _liquidityChange, BalanceDelta _feesAccrued) external onlyByPosm {
        notifyModifyLiquidityCount++;
        liquidityChange = _liquidityChange;
        feesAccrued = _feesAccrued;
    }

    function notifyTransfer(uint256, address, address) external onlyByPosm {
        notifyTransferCount++;
    }
}
