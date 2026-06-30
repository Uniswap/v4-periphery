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
    /// @notice A negative `additionalA/additionalB` (return-to-wallet) asked for more than was withdrawn.
    error ReturnExceedsWithdrawn(uint256 requested, uint256 withdrawn);
    /// @notice `compound` was called on a position with no accrued fees to reinvest.
    error NoFeesToCompound();

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

    /// @param tokenId           Existing position to top up. Its pool and tick range are read on-chain; the
    ///                          liquidity is ADDED to this same tokenId (no new NFT, the NFT never moves).
    /// @param amount0In         Budget of pool token0 to add (may be 0).
    /// @param amount1In         Budget of pool token1 to add (may be 0).
    /// @param route             Verbatim Universal Router payload for the surplus->deficit swap (may be empty).
    /// @param minLiquidityAdded Slippage floor: revert if the liquidity added to the position < this.
    /// @param recipient         Receives any swept leftover input-token dust (NOT the position — that stays put).
    /// @param hookData          Hook data forwarded to the increase.
    /// @param deadline          Tx reverts after this timestamp.
    struct IncreaseParams {
        uint256 tokenId;
        uint256 amount0In;
        uint256 amount1In;
        bytes route;
        uint256 minLiquidityAdded;
        address recipient;
        bytes hookData;
        uint256 deadline;
    }

    /// @notice Top up an EXISTING position with a one- or two-sided token budget in a single transaction. Same
    ///         route-first sizing as `add`, but it INCREASEs the given tokenId at its current range instead of
    ///         minting a new position — the NFT never moves and no new NFT is created. The contract must be
    ///         POSM-approved on the position (POSM gates INCREASE_LIQUIDITY on the locker being approved).
    /// @dev No CALLER auth is needed: funds come from `msg.sender` via `_pullBudget`, the position only grows (for
    ///      whoever owns it), and swept dust goes to `recipient` (the funder) — there is no value-redirect path,
    ///      so anyone may top up a position the contract is approved on, from their own wallet.
    /// @return liquidityAdded The liquidity added to the position.
    /// @return amount0        token0 added to the position.
    /// @return amount1        token1 added to the position.
    function increase(IncreaseParams calldata params)
        external
        payable
        returns (uint128 liquidityAdded, uint256 amount0, uint256 amount1);

    /// @param tokenId       Existing position to move; caller must be owner or approved. The position is
    ///                      withdrawn IN FULL (burned) — see DESIGN NOTE on the deltas below.
    /// @param additionalA   Signed delta for currency0, applied to the fully-withdrawn holdings of that token:
    ///                      > 0 pulls that many MORE units from the caller's wallet (rebalance + add in one tx),
    ///                      < 0 returns that many units to `recipient`'s wallet (rebalance + cash-out), 0 leaves
    ///                      the withdrawn amount as-is (a full move). The redeploy budget for currency0 is
    ///                      `withdrawn0 + additionalA`. A negative value may not exceed `withdrawn0`.
    /// @param additionalB   Signed delta for currency1, same semantics (`withdrawn1 + additionalB`). currency1 is
    ///                      never native ETH (native sorts to currency0), so a positive value is always an ERC20
    ///                      Permit2 pull.
    /// @param newTickLower  Lower tick of the new position.
    /// @param newTickUpper  Upper tick of the new position.
    /// @param route         Verbatim Universal Router payload for the surplus->deficit swap (may be empty).
    /// @param minLiquidity  Slippage floor on the NEW (post-trim) position.
    /// @param recipient     Receives the new POSM NFT, any returned (negative-delta) share, and any swept dust.
    ///                      HONORED ONLY when the caller is the position owner; if an approved operator calls,
    ///                      all output is forced to the owner so an operator can never redirect value to itself.
    /// @param hookData      Hook data forwarded to the mint.
    /// @param deadline      Tx reverts after this timestamp.
    struct RebalanceParams {
        uint256 tokenId;
        int128 additionalA;
        int128 additionalB;
        int24 newTickLower;
        int24 newTickUpper;
        bytes route;
        uint256 minLiquidity;
        address recipient;
        bytes hookData;
        uint256 deadline;
    }

    /// @notice Withdraw an existing position IN FULL and redeposit it into a new range, optionally adding to or
    ///         cashing out of each token, in one transaction. The position is always burned entirely; the
    ///         per-token redeploy budget is `withdrawn + additional` (the signed `additionalA/additionalB`), run
    ///         through the add flow (route + size + reconcile) into the new range. Any negative delta is returned
    ///         to `recipient`'s wallet up front. Always mints a NEW position (POSM ties a tokenId to a fixed range).
    /// @dev DESIGN NOTE — one signed knob for both add-more and cash-out: a rebalance is typically triggered by an
    ///      OUT-OF-RANGE position, whose liquidity earns nothing where it sits, so the whole position is withdrawn.
    ///      The signed deltas then let the caller redeploy exactly what they want: positive to top up from the
    ///      wallet, negative to peel a chosen amount back to the wallet, zero to redeploy the lot. Exact token
    ///      amounts (no basis-point rounding), and any mix of signs across the two tokens is allowed.
    /// @return newTokenId The newly minted position id.
    function rebalance(RebalanceParams calldata params)
        external
        payable
        returns (uint256 newTokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @param tokenId           Position whose accrued fees to reinvest; caller must be owner or approved, and the
    ///                          contract must be approved on the position (POSM acts on the caller's behalf).
    /// @param minLiquidityAdded Slippage floor: revert if the liquidity added by compounding < this.
    /// @param recipient         Receives any swept rounding dust (the fees themselves are reinvested, not paid out).
    ///                          Honored only when the caller is the owner; forced to the owner for an operator.
    /// @param hookData          Hook data forwarded to the fee collect and the increase.
    /// @param deadline          Tx reverts after this timestamp.
    struct CompoundParams {
        uint256 tokenId;
        uint256 minLiquidityAdded;
        address recipient;
        bytes hookData;
        uint256 deadline;
    }

    /// @notice Reinvest a position's accrued fees back INTO the same position, in one transaction. Collects the
    ///         fees (without touching principal), balances them to the position's current ratio via a single
    ///         same-pool swap, and INCREASEs the same tokenId. The fees never reach the caller's wallet
    ///         (compounding) and the NFT is never moved — only the existing position grows.
    /// @return liquidityAdded The liquidity added to the position by reinvesting the fees.
    /// @return amount0        token0 reinvested into the position.
    /// @return amount1        token1 reinvested into the position.
    function compound(CompoundParams calldata params)
        external
        returns (uint128 liquidityAdded, uint256 amount0, uint256 amount1);
}
