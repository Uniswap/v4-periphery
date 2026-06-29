// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title ISwapAndAdd
/// @notice Swap-and-add / rebalance zap for Uniswap v4. Lets a caller supply the two pool tokens in any
///         ratio (including only one) and, in a single transaction, receive a standard PositionManager (POSM)
///         ERC-721 position — the contract sources the missing token via a swap, using a route-first design.
/// @dev Flow (route first, then size from reality):
///      1. run the verbatim off-chain Universal Router `route` FIRST, swapping the surplus side toward the
///         deficit (best execution, off-venue), then read the contract's ACTUAL post-route balances,
///      2. size the position from those real holdings at the live price — fee-aware (discount the side the
///         same-pool reconcile will swap by the pool's lpFee+protocolFee) — and mint it to THIS contract (POSM),
///      3. one same-pool reconcile swap funds whichever side the mint is short of (either direction: top up if
///         the route under-converted, sell back if it over-converted), then a DECREASE ("trim") lands the
///         position exactly on what the holdings support,
///      4. enforce `minLiquidity`, sweep the small remainder (input-token dust) to `recipient`, and transfer the
///         NFT to `recipient` after the unlock closes.
///
///      DESIGN NOTE — route first, then size:
///      The route is sized off-chain and executes off-venue, so on-chain we don't know its rate ahead of time —
///      but by running it FIRST and sizing the position from the *actual* resulting holdings, the contract
///      deploys whatever the route really returned (it doesn't lose value to a cheaper-than-expected or
///      better-than-mid route, which a size-then-swap design would return to the wallet). The same-pool reconcile
///      runs AFTER the mint so its price impact can't invalidate the position's required ratio (the mint is
///      already fixed at the live price). `minLiquidity` is the single slippage knob: a floor on the FINAL
///      (post-trim) position; if price drift / MEV makes the holdings fund less than `minLiquidity`, the call
///      reverts. No swap-rate input, no separate min-amount params. With an empty `route`, the whole deficit is
///      sourced by the same-pool reconcile (the design degrades to a pure same-pool zap). The position is minted
///      to this contract so it can be trimmed, then transferred to `recipient`.
interface ISwapAndAdd {
    error DeadlinePassed(uint256 deadline);
    error InvalidEthValue();
    error InsufficientLiquidity(uint128 minLiquidity, uint128 liquidity);
    error NotAuthorizedForToken(uint256 tokenId);
    /// @notice `redeployBps` must be in (0, 10_000]: 0 would be a pure withdrawal (not a rebalance) and
    ///         values above 10_000 are nonsensical.
    error InvalidRedeployBps(uint256 redeployBps);

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

    /// @param tokenId       Existing position to move; caller must be owner or approved. The position is
    ///                      withdrawn IN FULL (burned) — see DESIGN NOTE on `redeployBps` below.
    /// @param redeployBps   Fraction of the fully-withdrawn value to redeploy into the new range, in basis
    ///                      points (0, 10_000]. 10_000 = redeploy everything (a full move); < 10_000 redeploys
    ///                      that share and returns the rest to `recipient`'s wallet. Must be > 0 (a 0% redeploy
    ///                      is a pure withdrawal, not a rebalance) and <= 10_000.
    /// @param newTickLower  Lower tick of the new position.
    /// @param newTickUpper  Upper tick of the new position.
    /// @param route         Verbatim Universal Router payload for the surplus->deficit swap (may be empty).
    /// @param minLiquidity  Slippage floor on the NEW (post-trim) position.
    /// @param recipient     Receives the new POSM NFT, the returned (1 - redeployBps) share, and any swept dust.
    /// @param hookData      Hook data forwarded to the mint.
    /// @param deadline      Tx reverts after this timestamp.
    struct RebalanceParams {
        uint256 tokenId;
        uint256 redeployBps;
        int24 newTickLower;
        int24 newTickUpper;
        bytes route;
        uint256 minLiquidity;
        address recipient;
        bytes hookData;
        uint256 deadline;
    }

    /// @notice Withdraw an existing position IN FULL and redeposit a chosen fraction into a new range, in one
    ///         transaction. The position is always burned entirely; `redeployBps` of the withdrawn value is run
    ///         through the add flow (route + size + reconcile) into the new range, and the remaining
    ///         (10_000 - redeployBps) is returned to `recipient`'s wallet. Always mints a NEW position (POSM ties
    ///         a tokenId to a fixed range).
    /// @dev DESIGN NOTE — why full-burn + return, not partial-decrease: a rebalance is typically triggered by an
    ///      OUT-OF-RANGE position, whose liquidity earns nothing where it sits. Leaving the un-moved portion in
    ///      the old range would keep it idle; returning it to the wallet lets the user actually use it. So the
    ///      whole position is withdrawn and only the redeployed share re-enters the pool.
    /// @return newTokenId The newly minted position id.
    function rebalance(RebalanceParams calldata params)
        external
        payable
        returns (uint256 newTokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}
