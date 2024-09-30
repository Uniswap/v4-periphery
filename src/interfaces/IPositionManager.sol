// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionInfo} from "../libraries/PositionInfoLibrary.sol";

import {INotifier} from "./INotifier.sol";

/// @title IPositionManager
/// @notice Interface for the PositionManager contract
interface IPositionManager is INotifier {
    /// @notice Thrown when the caller is not approved to modify a position
    error NotApproved(address caller);
    /// @notice Thrown when the block.timestamp exceeds the user-provided deadline
    error DeadlinePassed(uint256 deadline);

    /// @notice Unlocks Uniswap v4 PoolManager and batches actions for modifying liquidity
    /// @dev This is the standard entrypoint for the PositionManager
    /// @param unlockData is an encoding of actions, and parameters for those actions
    /// @param deadline is the deadline for the batched actions to be executed
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;

    /// @notice Batches actions for modifying liquidity without unlocking v4 PoolManager
    /// @dev This must be called by a contract that has already unlocked the v4 PoolManager
    /// @param actions the actions to perform
    /// @param params the parameters to provide for the actions
    function modifyLiquiditiesWithoutUnlock(bytes calldata actions, bytes[] calldata params) external payable;

    /// @notice Used to get the ID that will be used for the next minted liquidity position
    /// @return uint256 The next token ID
    function nextTokenId() external view returns (uint256);

    /// @param tokenId the ERC721 tokenId
    /// @return liquidity the position's liquidity, as a liquidityAmount
    /// @dev this value can be processed as an amount0 and amount1 by using the LiquidityAmounts library
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128 liquidity);

    /// @param tokenId the ERC721 tokenId
    /// @return PositionInfo a uint256 packed value holding information about the position including the range (tickLower, tickUpper)
    /// @return poolKey the pool key of the position
    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory, PositionInfo);
}
