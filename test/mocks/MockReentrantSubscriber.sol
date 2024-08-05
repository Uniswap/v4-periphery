// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {ISubscriber} from "../../src/interfaces/ISubscriber.sol";
import {PositionConfig} from "../../src/libraries/PositionConfig.sol";
import {PositionManager} from "../../src/PositionManager.sol";

/// @notice A subscriber contract that ingests updates from the v4 position manager
contract MockReentrantSubscriber is ISubscriber {
    PositionManager posm;

    bytes actions;
    bytes[] params;

    error NotAuthorizedNotifer(address sender);

    error NotImplemented();

    constructor(PositionManager _posm) {
        posm = _posm;
    }

    modifier onlyByPosm() {
        if (msg.sender != address(posm)) revert NotAuthorizedNotifer(msg.sender);
        _;
    }

    function notifySubscribe(uint256, PositionConfig memory, bytes memory data) external onlyByPosm {
        if (data.length != 0) {
            (bytes memory _actions, bytes[] memory _params) = abi.decode(data, (bytes, bytes[]));
            posm.modifyLiquiditiesWithoutUnlock(_actions, _params);
        }
    }

    function notifyUnsubscribe(uint256, PositionConfig memory, bytes memory data) external onlyByPosm {
        if (data.length != 0) {
            (bytes memory _actions, bytes[] memory _params) = abi.decode(data, (bytes, bytes[]));
            posm.modifyLiquiditiesWithoutUnlock(_actions, _params);
        }
    }

    function notifyModifyLiquidity(uint256, PositionConfig memory, int256) external onlyByPosm {
        if (actions.length != 0) {
            posm.modifyLiquiditiesWithoutUnlock(actions, params);
        }
    }

    function notifyTransfer(uint256 tokenId, address, address) external onlyByPosm {
        if (actions.length != 0) {
            posm.modifyLiquiditiesWithoutUnlock(actions, params);
        }
    }

    function setActionsAndParams(bytes memory _actions, bytes[] memory _params) external {
        actions = _actions;
        params = _params;
    }

    function clearActionsAndParams() external {
        actions = "";
        params = new bytes[](0);
    }
}
