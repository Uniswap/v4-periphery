// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {ISubscriber} from "../../src/interfaces/ISubscriber.sol";
import {PositionConfig} from "../../src/libraries/PositionConfig.sol";
import {PositionManager} from "../../src/PositionManager.sol";

/// @notice A subscriber contract that returns values from the subscriber entrypoints
contract MockReturnDataSubscriber is ISubscriber {
    PositionManager posm;

    uint256 public notifySubscribeCount;
    uint256 public notifyUnsubscribeCount;
    uint256 public notifyModifyLiquidityCount;
    uint256 public notifyTransferCount;

    error NotAuthorizedNotifer(address sender);

    error NotImplemented();

    uint256 memPtr;

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
        uint256 _memPtr = memPtr;
        assembly {
            let fmp := mload(0x40)
            mstore(fmp, 0xBEEF)
            mstore(add(fmp, 0x20), 0xCAFE)
            return(fmp, _memPtr)
        }
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

    function setReturnDataSize(uint256 _value) external {
        memPtr = _value;
    }
}
