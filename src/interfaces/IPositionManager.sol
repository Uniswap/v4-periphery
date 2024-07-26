// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

enum Actions {
    MINT,
    BURN,
    INCREASE,
    DECREASE,
    // Any positive delta on a currency will be sent to specified address
    CLOSE_CURRENCY
}

interface IPositionManager {
    error MismatchedLengths();
    error NotApproved(address caller);
    error DeadlinePassed();
    error UnsupportedAction();
    error IncorrectPositionConfigForTokenId(uint256 tokenId);

    /// @notice Maps the ERC721 tokenId to a configId, which is a keccak256 hash of the position's pool key, and range (tickLower, tickUpper)
    /// Enforces that a minted ERC721 token is tied to one range on one pool.
    /// @param tokenId the ERC721 tokenId, assigned at mint
    /// @return configId the hash of the position's poolkey, tickLower, and tickUpper
    function positionConfigs(uint256 tokenId) external view returns (bytes32 configId);

    /// @notice Batches many liquidity modification calls to pool manager
    /// @param payload is an encoding of actions, and parameters for those actions
    /// @param deadline is the deadline for the batched actions to be executed
    /// @return returnData is the endocing of each actions return information
    function modifyLiquidities(bytes calldata payload, uint256 deadline) external payable returns (bytes[] memory);

    function nextTokenId() external view returns (uint256);
}
