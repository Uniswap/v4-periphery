// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title ISwapAndAdd
/// @notice V1 swap-and-add / rebalance zap for Uniswap v4. Lets a caller supply the two pool tokens in any
///         ratio (including only one) and, in a single transaction, receive a standard PositionManager (POSM)
///         ERC-721 position — the contract sources the missing token via a swap, using a mint-first design.
/// @dev Flow (single mint, mint-first):
///      1. size target liquidity L on-chain from the budget + live slot0 (see DESIGN NOTE below),
///      2. flash-`take` the deficit token and mint the position directly to `recipient` (POSM),
///      3. run the verbatim off-chain Universal Router `route` for the bulk surplus->deficit swap,
///      4. one same-pool reconcile swap to land exactly on the position's need (top-up shortfall, or sell
///         excess of the swapped-into token back to the input token — leftover only ever in the input token),
///      5. settle, sweep leftover input to `recipient`.
///
///      DESIGN NOTE — L-sizing input (`swapRateX96`):
///      To size L on-chain from an arbitrary off-chain route we need the swap's effective rate (slot0 is the
///      fee-less mid and would over-size -> revert). An arbitrary route's rate is not derivable on-chain, so
///      off-chain passes a conservative (worst-acceptable) rate. The position *ratio* is still computed from
///      live slot0 on-chain. `swapRateX96` and `minLiquidity` are both derived off-chain from the SINGLE user
///      slippage tolerance (rate = quotedRate*(1-tol), minLiquidity = quotedL*(1-tol)) — one user-facing knob.
///      [V1 decision: "option A". Reversible to off-chain target-L if desired; only this sizing step changes.]
interface ISwapAndAdd {
    error DeadlinePassed(uint256 deadline);
    error InvalidEthValue();
    error InsufficientLiquidity(uint128 minLiquidity, uint128 liquidity);
    error NotAuthorizedForToken(uint256 tokenId);

    /// @param poolKey       Target v4 pool.
    /// @param tickLower     Lower tick of the position.
    /// @param tickUpper     Upper tick of the position.
    /// @param amount0In     Budget of pool token0 (may be 0).
    /// @param amount1In     Budget of pool token1 (may be 0).
    /// @param route         Verbatim Universal Router payload for the bulk swap: abi.encode(bytes commands, bytes[] inputs).
    ///                      May be empty -> the whole deficit is sourced by the same-pool reconcile swap.
    /// @param swapRateX96   Worst-acceptable effective swap rate, token1-per-token0, as Q96. Used only for on-chain L sizing.
    /// @param minLiquidity  Slippage floor: revert if the resulting position liquidity < minLiquidity.
    /// @param recipient     Receives the POSM NFT and any swept leftover input token.
    /// @param hookData      Hook data forwarded to the position mint.
    /// @param deadline      Tx reverts after this timestamp.
    struct AddParams {
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0In;
        uint256 amount1In;
        bytes route;
        uint256 swapRateX96;
        uint256 minLiquidity;
        address recipient;
        bytes hookData;
        uint256 deadline;
    }

    /// @notice Create a new v4 position from a one- or two-sided token budget in a single transaction.
    /// @return tokenId   The minted POSM position id.
    /// @return liquidity The liquidity added to the position.
    /// @return amount0   token0 deposited into the position.
    /// @return amount1   token1 deposited into the position.
    function add(AddParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @param tokenId         Existing position to move; caller must be owner or approved.
    /// @param liquidityToMove Liquidity to withdraw from `tokenId` (partial); equal to the position's full
    ///                        liquidity for a full rebalance.
    /// @param newTickLower    Lower tick of the new position.
    /// @param newTickUpper    Upper tick of the new position.
    /// @param route           Verbatim Universal Router payload for the surplus->deficit swap (may be empty).
    /// @param swapRateX96     Worst-acceptable effective swap rate, token1-per-token0, Q96 (sizing only).
    /// @param minLiquidity    Slippage floor on the NEW position.
    /// @param recipient       Receives the new POSM NFT and any swept leftover.
    /// @param hookData        Hook data forwarded to the mint.
    /// @param deadline        Tx reverts after this timestamp.
    struct RebalanceParams {
        uint256 tokenId;
        uint128 liquidityToMove;
        int24 newTickLower;
        int24 newTickUpper;
        bytes route;
        uint256 swapRateX96;
        uint256 minLiquidity;
        address recipient;
        bytes hookData;
        uint256 deadline;
    }

    /// @notice Withdraw (part of) an existing position and redeposit it into a new range, in one transaction.
    ///         Reuses the add flow with the withdrawn tokens (+ fees) as the starting budget. Always mints a
    ///         NEW position (POSM ties a tokenId to a fixed range); a partial rebalance leaves the original
    ///         position with its remaining liquidity.
    /// @return newTokenId The newly minted position id.
    function rebalance(RebalanceParams calldata params)
        external
        payable
        returns (uint256 newTokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}
