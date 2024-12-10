// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISubscriber} from "../../src/interfaces/ISubscriber.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PositionInfo} from "../../src/libraries/PositionInfoLibrary.sol";

/// @notice A subscriber contract that returns values from the subscriber entrypoints
contract MockReturnDataSubscriber is ISubscriber {
    IPositionManager posm;

    uint256 public notifySubscribeCount;
    uint256 public notifyUnsubscribeCount;
    uint256 public notifyModifyLiquidityCount;

    error NotAuthorizedNotifer(address sender);

    error NotImplemented();

    uint256 memPtr;

    constructor(IPositionManager _posm) {
        posm = _posm;
    }

    modifier onlyByPosm() {
        if (msg.sender != address(posm)) revert NotAuthorizedNotifer(msg.sender);
        _;
    }

    function notifySubscribe(uint256, bytes memory) external onlyByPosm {
        notifySubscribeCount++;
    }

    function notifyUnsubscribe(uint256) external onlyByPosm {
        notifyUnsubscribeCount++;
        uint256 _memPtr = memPtr;
        assembly {
            let fmp := mload(0x40)
            mstore(fmp, 0xBEEF)
            mstore(add(fmp, 0x20), 0xCAFE)
            return(fmp, _memPtr)
        }
    }

    function notifyModifyLiquidity(uint256, int256, BalanceDelta) external onlyByPosm {
        notifyModifyLiquidityCount++;
    }

    function notifyBurn(uint256, address, PositionInfo, uint256, BalanceDelta) external pure {
        return;
    }

    function setReturnDataSize(uint256 _value) external {
        memPtr = _value;
    }
}

/// @notice A subscriber contract that returns values from the subscriber entrypoints
contract MockRevertSubscriber is ISubscriber {
    IPositionManager posm;

    error NotAuthorizedNotifer(address sender);

    error TestRevert(string);

    constructor(IPositionManager _posm) {
        posm = _posm;
    }

    bool shouldRevert;

    modifier onlyByPosm() {
        if (msg.sender != address(posm)) revert NotAuthorizedNotifer(msg.sender);
        _;
    }

    function notifySubscribe(uint256, bytes memory) external view onlyByPosm {
        if (shouldRevert) {
            revert TestRevert("notifySubscribe");
        }
    }

    function notifyUnsubscribe(uint256) external view onlyByPosm {
        revert TestRevert("notifyUnsubscribe");
    }

    function notifyModifyLiquidity(uint256, int256, BalanceDelta) external view onlyByPosm {
        revert TestRevert("notifyModifyLiquidity");
    }

    function notifyBurn(uint256, address, PositionInfo, uint256, BalanceDelta) external pure {
        return;
    }

    function setRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }
}
