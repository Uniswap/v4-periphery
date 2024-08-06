// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PositionConfig} from "../libraries/PositionConfig.sol";

import {INotifier} from "./INotifier.sol";
import {IPoolInitializer} from "./IPoolInitializer.sol";

interface IPositionManager is INotifier, IPoolInitializer {
    error NotApproved(address caller);
    error DeadlinePassed();
    error IncorrectPositionConfigForTokenId(uint256 tokenId);

    event MintPosition(uint256 indexed tokenId, PositionConfig config);

    /// @notice Unlocks Uniswap v4 PoolManager and batches actions for modifying liquidity
    /// @dev This is the standard entrypoint for the PositionManager
    /// @param payload is an encoding of actions, and parameters for those actions
    /// @param deadline is the deadline for the batched actions to be executed
    function modifyLiquidities(bytes calldata payload, uint256 deadline) external payable;

    /// @notice Batches actions for modifying liquidity without unlocking v4 PoolManager
    /// @dev This must be called by a contract that has already unlocked the v4 PoolManager
    /// @param actions the actions to perform
    /// @param params the parameters to provide for the actions
    function modifyLiquiditiesWithoutUnlock(bytes calldata actions, bytes[] calldata params) external payable;

    /// @notice Used to get the ID that will be used for the next minted liquidity position
    /// @return uint256 The next token ID
    function nextTokenId() external view returns (uint256);
}
