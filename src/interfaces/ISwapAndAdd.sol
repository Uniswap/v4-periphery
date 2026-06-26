// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title ISwapAndAdd
/// @notice V1 swap-and-add / rebalance zap for Uniswap v4. Lets a caller supply the two pool tokens in any
///         ratio (including only one) and, in a single transaction, receive a standard PositionManager (POSM)
///         ERC-721 position — the contract sources the missing token via a swap, using an optimistic-mint design.
/// @dev Flow (optimistic mint + trim):
///      1. size the OPTIMISTIC max liquidity L the budget could fund if the swap executed at the live mid price
///         (zero loss) — read from slot0, no off-chain rate needed,
///      2. flash-`take` the deficit token and mint that L directly to THIS contract (POSM),
///      3. run the verbatim off-chain Universal Router `route` for the bulk surplus->deficit swap,
///      4. swap any remaining surplus same-pool (never overshooting), then DECREASE ("trim") the position by
///         exactly the liquidity whose freed deficit covers what the real swap fell short by,
///      5. settle, sweep the small in-ratio remainder (input-token dust) to `recipient`, and transfer the NFT to
///         `recipient` after the unlock closes.
///
///      DESIGN NOTE — sizing & slippage:
///      Real execution is always at-or-worse than the mid used to size L, so the position can only ever come up
///      SHORT and is trimmed DOWN — never the reverse. This deploys the *actual* maximum the budget supports (not
///      a conservative guess), so leftover dust is just the genuine slippage shortfall, in the input token.
///      `minLiquidity` is the single slippage knob: a floor on the FINAL (post-trim) position. If price drift or
///      MEV makes the budget fund less than `minLiquidity`, the call reverts. No swap-rate input, no separate
///      min-amount params. The position is minted to this contract so it can be trimmed, then transferred to
///      `recipient`.
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
    ///                      May be empty -> the whole deficit is sourced by the same-pool swap + trim.
    /// @param minLiquidity  Slippage floor: revert if the resulting (post-trim) position liquidity < minLiquidity.
    /// @param recipient     Receives the POSM NFT (after the unlock) and any swept leftover input token.
    /// @param hookData      Hook data forwarded to the position mint.
    /// @param deadline      Tx reverts after this timestamp.
    struct AddParams {
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0In;
        uint256 amount1In;
        bytes route;
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
    /// @param minLiquidity    Slippage floor on the NEW (post-trim) position.
    /// @param recipient       Receives the new POSM NFT and any swept leftover.
    /// @param hookData        Hook data forwarded to the mint.
    /// @param deadline        Tx reverts after this timestamp.
    struct RebalanceParams {
        uint256 tokenId;
        uint128 liquidityToMove;
        int24 newTickLower;
        int24 newTickUpper;
        bytes route;
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
