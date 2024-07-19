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

interface INonfungiblePositionManager {
    error MismatchedLengths();
    error NotApproved(address caller);
    error DeadlinePassed();
    error UnsupportedAction();
    error PositionMustBeEmpty();

    // TODO: This will just return a positionId
    function tokenRange(uint256 tokenId)
        external
        view
        returns (PoolKey memory poolKey, int24 tickLower, int24 tickUpper);

    /// @notice Batches many liquidity modification calls to pool manager
    /// @param payload is an encoding of actions, params, and currencies
    /// @param deadline is the deadline for the batched actions to be executed
    /// @return returnData is the endocing of each actions return information
    function modifyLiquidities(bytes calldata payload, uint256 deadline) external returns (bytes[] memory);

    function nextTokenId() external view returns (uint256);
}
