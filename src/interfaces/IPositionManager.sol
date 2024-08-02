// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {INotifier} from "./INotifier.sol";

interface IPositionManager is INotifier {
    error NotApproved(address caller);
    error DeadlinePassed();
    error IncorrectPositionConfigForTokenId(uint256 tokenId);

    /// @notice Batches many liquidity modification calls to pool manager
    /// @param payload is an encoding of actions, and parameters for those actions
    /// @param deadline is the deadline for the batched actions to be executed
    function modifyLiquidities(bytes calldata payload, uint256 deadline) external payable;

    function nextTokenId() external view returns (uint256);

    /// @param tokenId the ERC721 tokenId
    /// @return configId a truncated hash of the position's poolkey, tickLower, and tickUpper
    /// @dev truncates the least significant bit of the hash
    function getPositionConfigId(uint256 tokenId) external view returns (bytes32 configId);
}
