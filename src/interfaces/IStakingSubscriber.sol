// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {PositionConfig} from "../libraries/PositionConfig.sol";

interface IStakingSubscriber {
    function notifyStake(uint256 tokenId, uint256 liquidity, PositionConfig memory config) external;
    function notifyUnstake(uint256 tokenId, PositionConfig memory config) external;
    function notifyModifyLiquidity(uint256 tokenId, int256 liquidityChange, PositionConfig memory config) external;
    function notifyTransfer(uint256 tokenId, address previousOwner, address newOwner, PositionConfig memory config)
        external;
}
