// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {LiquidityRange, LiquidityRangeId} from "../types/LiquidityRange.sol";

interface IBaseLiquidityManagement {
    error PositionMustBeEmpty();
    error TokensMustBeCollected();

    // details about the liquidity position
    struct Position {
        uint256 liquidity;
        // the fee growth of the aggregate position as of the last action on the individual position
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        // how many uncollected tokens are owed to the position, as of the last computation
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    error LockFailure();

    /// @notice Fees owed for a given liquidity position. Includes materialized fees and uncollected fees.
    /// @param owner The owner of the liquidity position
    /// @param range The range of the liquidity position
    /// @return token0Owed The amount of token0 owed to the owner
    /// @return token1Owed The amount of token1 owed to the owner
    function feesOwed(address owner, LiquidityRange memory range)
        external
        view
        returns (uint256 token0Owed, uint256 token1Owed);
}
