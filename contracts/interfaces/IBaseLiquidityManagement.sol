// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {LiquidityRange, LiquidityRangeId} from "../types/LiquidityRange.sol";

interface IBaseLiquidityManagement {
    // details about the liquidity position
    struct Position {
        // the nonce for permits
        uint96 nonce;
        // the address that is approved for spending this token
        address operator;
        uint256 liquidity;
        // the fee growth of the aggregate position as of the last action on the individual position
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        // how many uncollected tokens are owed to the position, as of the last computation
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    enum LiquidityOperation {
        INCREASE,
        DECREASE,
        COLLECT
    }

    /// @notice Zero-out outstanding deltas for the PoolManager
    /// @dev To be called for batched operations where delta-zeroing happens once at the end of a sequence of operations
    /// @param delta The amounts to zero out. Negatives are paid by the sender, positives are collected by the sender
    /// @param currency0 The currency of the token0
    /// @param currency1 The currency of the token1
    /// @param user The user zero'ing the deltas. I.e. negative delta (debit) is paid by the user, positive delta (credit) is collected to the user
    /// @param claims Whether deltas are zeroed with ERC-6909 claim tokens
    function zeroOut(BalanceDelta delta, Currency currency0, Currency currency1, address user, bool claims) external;

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
