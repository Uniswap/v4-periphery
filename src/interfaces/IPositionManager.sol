// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IPositionManager {
    error NotApproved(address caller);
    error DeadlinePassed();
    error IncorrectPositionConfigForTokenId(uint256 tokenId);

    /// @notice Maps the ERC721 tokenId to a configId, which is a keccak256 hash of the position's pool key, and range (tickLower, tickUpper)
    /// Enforces that a minted ERC721 token is tied to one range on one pool.
    /// @param tokenId the ERC721 tokenId, assigned at mint
    /// @return configId a truncated hash of the position's poolkey, tickLower, and tickUpper and a reserved upper bit for the isSubscribed flag
    /// @dev the highest bit of the configId is used to signal if the position is subscribed
    /// and the lower bits contain the truncated hash of the PositionConfig
    function positionConfigs(uint256 tokenId) external view returns (bytes32 configId);

    /// @notice Batches many liquidity modification calls to pool manager
    /// @param payload is an encoding of actions, and parameters for those actions
    /// @param deadline is the deadline for the batched actions to be executed
    function modifyLiquidities(bytes calldata payload, uint256 deadline) external payable;

    function nextTokenId() external view returns (uint256);
}
