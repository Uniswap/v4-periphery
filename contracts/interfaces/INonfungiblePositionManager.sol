// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityRange} from "../types/LiquidityRange.sol";
// TODO: ADD/REMOVE ACTIONS

enum Actions {
    MINT,
    BURN,
    COLLECT,
    INCREASE,
    DECREASE
}

interface INonfungiblePositionManager {
    struct TokenPosition {
        address owner;
        LiquidityRange range;
    }

    error MustBeUnlockedByThisContract();
    error DeadlinePassed();
    error UnsupportedAction();

    /// @notice Batches many liquidity modification calls to pool manager
    /// @param payload is an encoding of actions, params, and currencies
    /// @return returnData is the endocing of each actions return information
    function modifyLiquidities(bytes calldata payload) external returns (bytes[] memory);

    // TODO Can decide if we want burn to auto encode a decrease/collect.
    /// @notice Burn a position and delete the tokenId
    /// @dev It enforces that there is no open liquidity or tokens to be collected
    /// @param tokenId The ID of the position
    // function burn(uint256 tokenId) external;

    /// @notice Returns the fees owed for a position. Includes unclaimed fees + custodied fees + claimable fees
    /// @param tokenId The ID of the position
    /// @return token0Owed The amount of token0 owed
    /// @return token1Owed The amount of token1 owed
    function feesOwed(uint256 tokenId) external view returns (uint256 token0Owed, uint256 token1Owed);

    function nextTokenId() external view returns (uint256);
}
