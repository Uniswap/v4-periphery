// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityRange} from "../types/LiquidityRange.sol";

enum Actions {
    MINT,
    BURN,
    INCREASE,
    DECREASE,
    CLOSE_CURRENCY // Any positive delta on a currency will be sent to specified address

}

interface INonfungiblePositionManager {
    error MismatchedLengths();
    error NotApproved(address caller);

    struct TokenPosition {
        address owner;
        LiquidityRange range;
        address operator;
    }

    error MustBeUnlockedByThisContract();
    error DeadlinePassed();
    error UnsupportedAction();

    function tokenPositions(uint256 tokenId) external view returns (address, LiquidityRange memory, address);

    /// @notice Batches many liquidity modification calls to pool manager
    /// @param payload is an encoding of actions, params, and currencies
    /// @param deadline is the deadline for the batched actions to be executed
    /// @return returnData is the endocing of each actions return information
    function modifyLiquidities(bytes calldata payload, uint256 deadline) external returns (bytes[] memory);

    /// TODO Can decide if we want burn to auto encode a decrease/collect.
    //// @notice Burn a position and delete the tokenId
    //// @dev It enforces that there is no open liquidity or tokens to be collected
    //// @param tokenId The ID of the position
    //// function burn(uint256 tokenId) external;

    function nextTokenId() external view returns (uint256);
}
