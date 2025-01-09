// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionInfo} from "../libraries/PositionInfoLibrary.sol";

import {INotifier} from "./INotifier.sol";
import {IImmutableState} from "./IImmutableState.sol";
import {IERC721Permit_v4} from "./IERC721Permit_v4.sol";
import {IEIP712_v4} from "./IEIP712_v4.sol";
import {IMulticall_v4} from "./IMulticall_v4.sol";
import {IPoolInitializer_v4} from "./IPoolInitializer_v4.sol";
import {IUnorderedNonce} from "./IUnorderedNonce.sol";
import {IPermit2Forwarder} from "./IPermit2Forwarder.sol";

/// @title IPositionManager
/// @notice Interface for the PositionManager contract
interface IPositionManager is
    INotifier,
    IImmutableState,
    IERC721Permit_v4,
    IEIP712_v4,
    IMulticall_v4,
    IPoolInitializer_v4,
    IUnorderedNonce,
    IPermit2Forwarder
{
    /// @notice Thrown when the caller is not approved to modify a position
    error NotApproved(address caller);
    /// @notice Thrown when the block.timestamp exceeds the user-provided deadline
    error DeadlinePassed(uint256 deadline);
    /// @notice Thrown when calling transfer, subscribe, or unsubscribe when the PoolManager is unlocked.
    /// @dev This is to prevent hooks from being able to trigger notifications at the same time the position is being modified.
    error PoolManagerMustBeLocked();

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

    /// @notice Returns the liquidity of a position
    /// @param tokenId the ERC721 tokenId
    /// @return liquidity the position's liquidity, as a liquidityAmount
    /// @dev this value can be processed as an amount0 and amount1 by using the LiquidityAmounts library
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128 liquidity);

    /// @notice Returns the pool key and position info of a position
    /// @param tokenId the ERC721 tokenId
    /// @return poolKey the pool key of the position
    /// @return PositionInfo a uint256 packed value holding information about the position including the range (tickLower, tickUpper)
    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory, PositionInfo);

    /// @notice Returns the position info of a position
    /// @param tokenId the ERC721 tokenId
    /// @return a uint256 packed value holding information about the position including the range (tickLower, tickUpper)
    function positionInfo(uint256 tokenId) external view returns (PositionInfo);
}
