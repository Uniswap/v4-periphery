// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {PositionConfig} from "../libraries/PositionConfig.sol";

/// @title Pool Initializer
/// @notice Initializes a pool on PoolManager
interface IPositionActionsRouter {
    error NotApproved(address caller);
    error IncorrectPositionConfigForTokenId(uint256 tokenId);

    event MintPosition(uint256 indexed tokenId, PositionConfig config);
}
