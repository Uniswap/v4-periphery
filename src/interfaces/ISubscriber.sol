// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {PositionConfig} from "../libraries/PositionConfig.sol";

interface ISubscriber {
    function notifySubscribe(uint256 tokenId, PositionConfig memory config) external;
    function notifyUnsubscribe(uint256 tokenId, PositionConfig memory config) external;
    function notifyModifyLiquidity(uint256 tokenId, PositionConfig memory config, int256 liquidityChange) external;
    function notifyTransfer(uint256 tokenId, address previousOwner, address newOwner) external;
}
