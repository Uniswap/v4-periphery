// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IMulticall_v4} from "./IMulticall_v4.sol";

/// @title ISwapAndAdd
/// @notice Swap-and-add zap for Uniswap v4: add / rebalance / increase / compound. Lets a caller supply the
///         two pool tokens in any ratio (including only one) and, in a single transaction, end up with a
///         standard PositionManager (POSM) ERC-721 position — newly minted (add, rebalance) or grown in place
///         (increase, compound) — the contract sources the missing token via a swap, using a route-first design.
/// @dev Flow (route first, then size from reality):
///      1. run the verbatim off-chain Universal Router `route` FIRST, swapping the surplus side toward the
///         deficit (best execution, typically off-venue), then read the contract's ACTUAL post-route balances,
///      2. size the position from those real holdings at the live price — fee-aware (discount the side the
///         same-pool reconcile will swap by that direction's total swap fee: lp fee compounded with the
///         directional protocol fee) — and mint it to THIS contract (POSM),
///      3. one same-pool reconcile swap funds whichever side the mint is short of (either direction: top up if
///         the route under-converted, sell back if it over-converted), then a DECREASE ("trim") lands the
///         position exactly on what the holdings support,
///      4. enforce `minLiquidity`, sweep the small remainder (dust, possibly in both pool tokens) to
///         `recipient`, and transfer the
///         NFT to `recipient` after the unlock closes.
///
///      DESIGN NOTE — route first, then size:
///      The route is a black box sized off-chain — on-chain we don't know (or care) what it does or at what
///      rate; it may even touch this pool. By running it FIRST, the post-route state (balances and pool price)
///      is the source of truth everything else works from: the contract deploys whatever the route really
///      returned (it doesn't lose value to a cheaper-than-expected or better-than-mid route, which a
///      size-then-swap design would return to the wallet). The same-pool reconcile
///      runs AFTER the mint so its price impact can't invalidate the position's required ratio (the mint is
///      already fixed at the live price). `minLiquidity` is the single slippage knob: a floor on the FINAL
///      (post-trim) position; if price drift / MEV makes the holdings fund less than `minLiquidity`, the call
///      reverts. No swap-rate input, no separate min-amount params. With an empty `route`, the whole deficit is
///      sourced by the same-pool reconcile (the design degrades to a pure same-pool zap). The position is minted
///      to this contract so it can be trimmed, then transferred to `recipient`.
///
///      UNSUPPORTED POOLS — hooks that return deltas: the reconcile relies on a conservation identity (the
///      same-pool swap's output plus what the trim frees covers the flash-taken deficit, because both come out
///      of the just-added liquidity). A hook that takes a cut of the amounts flowing through this contract's
///      own actions breaks that identity. Screen a pool mechanically by the hook address's permission bits
///      (v4-core `Hooks.sol`) rather than by intent:
///        - `AFTER_SWAP_RETURNS_DELTA` / `BEFORE_SWAP_RETURNS_DELTA` — skims the reconcile swap's output, so it
///          no longer covers the flash debt. UNSUPPORTED.
///        - `AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA` — skims what the trim, the fee collect or a rebalance burn
///          frees, so the trim frees less than computed (or the delta turns negative). UNSUPPORTED.
///        - `AFTER_ADD_LIQUIDITY_RETURNS_DELTA` — charges the deploy instead, which this contract settles from
///          the operation's budget: it behaves as an extra cost that leaves less for the position, gated by
///          `minLiquidity` rather than breaking settlement. Expected to degrade gracefully; NOT verified by
///          tests, so treat as unsupported until it is.
///      On an unsupported pool the call reverts atomically inside the unlock (CurrencyNotSettled, or
///      DeltaNotPositive from a removal whose delta went negative) — funds are always safe, but the operation
///      can simply be unusable there.
///      Hooks WITHOUT any of those four permissions are supported, including dynamic LP-fee hooks (a
///      `beforeSwap` fee override under `DYNAMIC_FEE_FLAG` returns a fee, not a delta) — see the DYNAMIC-FEE
///      NOTE below — as well as gating, oracle and accounting hooks, which only observe the callbacks.
///
///      KNOWN LIMIT — wei-scale budgets: the pool keeps up to 1 wei per side on any mint->decrease round trip
///      (mint amounts are pulled rounded UP, decrease amounts returned rounded DOWN). A budget within a few wei
///      of that toll cannot fully settle no matter how much of the just-added liquidity the trim removes: the
///      trim caps at everything that was added, the resulting liquidity is 0, and any non-zero `minLiquidity`
///      surfaces it as InsufficientLiquidity; only a zero floor (the explicit accept-anything opt-out) sees
///      v4's CurrencyNotSettled instead. Real-size budgets cannot reach this regime.
///
///      KNOWN LIMIT — fee-on-transfer and rebasing tokens are unsupported: as pool currencies (v4 itself does
///      not support them) and as routeFunding. Failures are atomic reverts or a larger trim, never a loss.
///
///      DYNAMIC-FEE NOTE: optimistic sizing uses the pool's stored Slot0 LP fee. A `beforeSwap` hook may select a
///      different per-swap override that cannot be generically previewed (it may depend on the caller, amount,
///      hookData or mutable state). The actual override is charged by the reconcile swap; if it is higher than
///      the stored fee, the position is trimmed further. `minLiquidity` is checked only after that trim and is
///      therefore the safety/slippage boundary for dynamic-fee pools as well. The call either meets the floor or
///      reverts atomically; only the optimistic sizing and gas efficiency can differ from the Slot0 estimate.
///      The same `hookData` is presented to every hook callback the operation triggers — up to four liquidity
///      actions (burn/collect, mint/increase, trim) and two reconcile swaps — so hooks must tolerate the
///      payload being reused; single-use/nonce payload schemes are unsupported.
///
///      MULTICALL NOTE: the contract supports POSM-style `multicall` (self-delegatecall per subcall, reverts
///      bubbled, atomic). The flagship batch is `[permitBatch, op]` — wire the caller's Permit2 allowances
///      from a signature and operate in one transaction; the inherited permit forwards swallow an inner
///      revert, so a front-run permit submission cannot brick the batch. Batching adds no fund-mixing
///      surface: delegatecall preserves msg.sender (subcalls only ever pull the batcher's own funds) and
///      every operation sweeps before returning (no-funds-at-rest holds per OP, not per transaction), so a
///      subcall starts against the same empty contract a fresh transaction would see. msg.value keeps
///      exactly one meaning per batch: every op asserts `msg.value == expected`, so an ERC20-only op
///      (expecting 0) cannot ride in a value-bearing batch, and while two native ops expecting the same
///      value both pass the CHECK, native spending is balance-funded — the second finds the balance already
///      consumed and reverts InvalidEthValue at its pull, unwinding the whole batch. Zero-value batches of
///      ERC20 ops compose freely (e.g. a keeper increasing/compounding several positions in one transaction).
///      Batch value no op consumes (e.g. value attached to a permits-only batch) strands in the contract as
///      an unsolicited donation — see the ETH NOTE.
///
///      ETH NOTE: inherited Permit2 forwarding calls are payable for composability (a value-bearing batch
///      contains them alongside the one op that consumes the value) even though they consume no ETH
///      themselves. Do not attach value to a DIRECT call to them. Such value is an unsolicited donation and
///      may be swept to the recipient of a later operation involving native ETH; it does not create a claim
///      for the sender.
interface ISwapAndAdd is IMulticall_v4 {
    /// @notice The zero address is not allowed.
    error ZeroAddress();
    /// @notice A new position was minted via `add` and delivered to `recipient`.
    event Added(
        address indexed recipient,
        uint256 indexed tokenId,
        address caller,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );
    /// @notice `oldTokenId` was burned and redeployed as `newTokenId` (delivered to `recipient`) via `rebalance`.
    event Rebalanced(
        address indexed recipient,
        uint256 indexed oldTokenId,
        uint256 indexed newTokenId,
        address caller,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );
    /// @notice `tokenId` grew in place via `increase`. `recipient` is the RESOLVED recipient — the leftover /
    ///         dust destination, forced to the owner for an operator caller.
    event Increased(
        address indexed recipient,
        uint256 indexed tokenId,
        address caller,
        uint128 liquidityAdded,
        uint256 amount0,
        uint256 amount1
    );
    /// @notice `tokenId`'s accrued fees were reinvested via `compound`; recipient semantics as in `Increased`.
    event Compounded(
        address indexed recipient,
        uint256 indexed tokenId,
        address caller,
        uint128 liquidityAdded,
        uint256 amount0,
        uint256 amount1
    );

    error DeadlinePassed(uint256 deadline);
    /// @notice msg.value does not match the operation's declared native amount, or the contract's native
    ///         balance cannot cover it (a value-bearing multicall where an earlier subcall already spent it).
    error InvalidEthValue();
    /// @notice Plain ETH transfers are rejected; only the PoolManager, POSM and the Universal Router may send.
    error InvalidEthSender();
    error InsufficientLiquidity(uint256 minLiquidity, uint128 liquidity);
    /// @notice Output may not be sent to this contract (it would strand there) or to the zero address (the
    ///         NFT hand-off rejects it late; swept leftovers would burn silently on the grow ops).
    error InvalidRecipient(address recipient);
    error NotAuthorizedForToken(uint256 tokenId);
    /// @notice A negative `additional0/additional1` (return-to-wallet) asked for more than was withdrawn.
    error ReturnExceedsWithdrawn(uint256 requested, uint256 withdrawn);
    /// @notice Nothing to deploy: the operation has no pulled budget, the position has no accrued fees and
    ///         there is no route that could produce a budget (compound on a fee-less position, or an empty
    ///         increase).
    error NoFeesToCompound();
    /// @notice `routeFunding` entries are route input by definition; without a `route` they would only
    ///         round-trip to the recipient.
    error RouteFundingRequiresRoute();
    /// @notice A `routeFunding` entry is a pool currency of the operation — pool tokens are budget, not
    ///         funding: pass them as `amount0In`/`amount1In` (on a native pool this also rejects address(0),
    ///         keeping msg.value's two possible meanings mutually exclusive).
    error InvalidFundingToken(Currency token);

    /// @notice One route-funding entry: a non-pool token pulled from the caller solely to fund the route.
    ///         See `AddParams.routeFunding`.
    struct TokenAmount {
        Currency token;
        uint256 amount;
    }

    /// @param poolKey       Target v4 pool.
    /// @param tickLower     Lower tick of the position.
    /// @param tickUpper     Upper tick of the position.
    /// @param amount0In     Budget of pool token0 (may be 0).
    /// @param amount1In     Budget of pool token1 (may be 0).
    /// @param route         Verbatim Universal Router payload for the bulk swap: abi.encode(bytes commands, bytes[] inputs).
    ///                      May be empty -> the whole deficit is sourced by the same-pool swap + trim. The route
    ///                      declares its own input token and amount; BOTH pool tokens are funded for it (standing
    ///                      Permit2 allowances / native value), whatever it does not consume stays in the contract
    ///                      for the same-pool reconcile, and native value left in the router is reclaimed.
    ///                      ROUTE-CONSTRUCTION REQUIREMENT: the contract forwards its WHOLE native balance with
    ///                      the route, so route commands must scope their input amounts explicitly — never
    ///                      consume "the entire balance" (e.g. WRAP_ETH with CONTRACT_BALANCE): value wrapped or
    ///                      spent beyond the declared input is taken from the operation's budget, and WETH left
    ///                      inside the router is NOT reclaimed (only native is).
    /// @param routeFunding  OPTIONAL non-pool tokens pulled from the caller solely to fund the `route` (zap-in
    ///                      from arbitrary tokens: e.g. supply USDC, route it into the pool's two tokens). Each
    ///                      entry is Permit2-pulled up front; whatever of it the route leaves unconsumed is
    ///                      swept to `recipient` after the operation. Entries must not be pool currencies
    ///                      (those are `amount0In`/`amount1In`) and require a non-empty `route`. Native ETH may
    ///                      be an entry (token = address(0)) only when currency0 is not native, and msg.value
    ///                      must equal that entry's amount — msg.value always has exactly one meaning. A
    ///                      zero-amount entry pulls nothing but is still swept: it claims any donated balance
    ///                      of that token (consistent with the donation doctrine in the contract INVARIANT).
    ///                      Fee-on-transfer tokens are unsupported (the route's declared input would exceed the
    ///                      delivered balance), matching the pool-token policy.
    /// @param minLiquidity  Slippage floor: revert if the resulting (post-trim) position liquidity < minLiquidity.
    /// @param recipient     Receives the POSM NFT (after the unlock) and any swept leftovers (possibly in both
    ///                      pool tokens, plus unconsumed route funding). Must not
    ///                      be this SwapAndAdd contract.
    /// @param hookData      Hook data forwarded to the position mint, reconcile swaps and any trim.
    /// @param deadline      Tx reverts after this timestamp.
    struct AddParams {
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0In;
        uint256 amount1In;
        bytes route;
        TokenAmount[] routeFunding;
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
    ///                          Caller must be the owner or an ERC-721-approved operator of the position.
    /// @param amount0In         Budget of pool token0 to pull and add (may be 0). The position's accrued fees
    ///                          are collected and deployed ON TOP of the pulled budget — to target a total,
    ///                          state `target - current unclaimed fees` per side (offchain netting).
    /// @param amount1In         Budget of pool token1 to pull and add (may be 0); fee semantics as amount0In.
    /// @param route             Verbatim Universal Router payload for the surplus->deficit swap (may be empty;
    ///                          funding semantics as in `AddParams.route`). The collected fees are part of the
    ///                          held budget the route may consume.
    /// @param routeFunding      OPTIONAL non-pool tokens pulled from the caller solely to fund the `route`;
    ///                          full semantics in `AddParams.routeFunding`. Requires a non-empty `route`;
    ///                          leftovers are swept to the RESOLVED recipient (forced to the owner for an
    ///                          operator — a route can also produce a funding token from position value, so
    ///                          funding leftovers are output like any other).
    /// @param minLiquidityAdded Slippage floor: revert if the liquidity added to the position < this. Quote it
    ///                          against budget PLUS unclaimed fees, or the fee credit becomes slack in the floor.
    /// @param recipient         Receives any swept leftover dust, possibly in both pool tokens (NOT the
    ///                          position — that stays put).
    ///                          Honored only when the caller is the owner; forced to the owner for an operator.
    ///                          Must not be this SwapAndAdd contract.
    /// @param hookData          Hook data forwarded to the fee collect, increase, reconcile swaps and any trim.
    /// @param deadline          Tx reverts after this timestamp.
    struct IncreaseParams {
        uint256 tokenId;
        uint256 amount0In;
        uint256 amount1In;
        bytes route;
        TokenAmount[] routeFunding;
        uint256 minLiquidityAdded;
        address recipient;
        bytes hookData;
        uint256 deadline;
    }

    /// @notice Top up an EXISTING position with a one- or two-sided token budget in a single transaction. Same
    ///         route-first sizing as `add`, but it INCREASEs the given tokenId at its current range instead of
    ///         minting a new position — the NFT never moves and no new NFT is created. The position's accrued
    ///         fees are collected first and reinvested alongside the pulled budget (they fund the route and
    ///         the sizing; they never leave to the wallet beyond rounding dust). The contract must be
    ///         POSM-approved on the position (POSM gates the fee collect and INCREASE_LIQUIDITY on the locker
    ///         being approved).
    /// @dev CALLER auth required (owner or ERC-721-approved operator): the fee collect spends position value,
    ///      so an open entrypoint would let anyone force-churn a position's fees through caller-chosen route /
    ///      floor. For an operator, all output is forced to the owner. The fee collect is a DECREASE by 0, so
    ///      pools with remove-liquidity hooks see those callbacks on every increase. Reverts NoFeesToCompound
    ///      when there is nothing to deploy (zero budget, zero fees and no route that could produce a budget).
    /// @return liquidityAdded The liquidity added to the position.
    /// @return amount0        token0 added to the position.
    /// @return amount1        token1 added to the position.
    function increase(IncreaseParams calldata params)
        external
        payable
        returns (uint128 liquidityAdded, uint256 amount0, uint256 amount1);

    /// @param tokenId       Existing position to move; caller must be owner or approved. TWO distinct approvals
    ///                      are involved: the owner/operator check authorizes the CALLER, and — separately —
    ///                      this contract must itself be ERC-721-approved on the tokenId (approve /
    ///                      setApprovalForAll on POSM), because POSM authorizes the burn against this contract
    ///                      as the locker. The position is withdrawn IN FULL (burned) — see DESIGN NOTE on the
    ///                      deltas below.
    /// @param additional0   Signed delta for currency0, applied to the fully-withdrawn holdings of that token:
    ///                      > 0 pulls that many MORE units from the caller's wallet (rebalance + add in one tx),
    ///                      < 0 returns that many units to `recipient`'s wallet (rebalance + cash-out), 0 leaves
    ///                      the withdrawn amount as-is (a full move). The redeploy budget for currency0 is
    ///                      `withdrawn0 + additional0`. A negative value may not exceed `withdrawn0`.
    /// @param additional1   Signed delta for currency1, same semantics (`withdrawn1 + additional1`). currency1 is
    ///                      never native ETH (native sorts to currency0), so a positive value is always an ERC20
    ///                      Permit2 pull.
    /// @param newTickLower  Lower tick of the new position.
    /// @param newTickUpper  Upper tick of the new position.
    /// @param route         Verbatim Universal Router payload for the surplus->deficit swap (may be empty;
    ///                      funding semantics as in `AddParams.route`).
    /// @param routeFunding  OPTIONAL non-pool tokens pulled from the caller solely to fund the `route`; full
    ///                      semantics in `AddParams.routeFunding`. Requires a non-empty `route`; leftovers are
    ///                      swept to the RESOLVED recipient (forced to the owner for an operator).
    /// @param minLiquidity  Slippage floor on the NEW (post-trim) position.
    /// @param recipient     Receives the new POSM NFT, any returned (negative-delta) share, and any swept dust.
    ///                      HONORED ONLY when the caller is the position owner; if an approved operator calls,
    ///                      all output is forced to the owner so an operator can never redirect value to itself.
    ///                      The resolved recipient must not be this SwapAndAdd contract.
    /// @param hookData      Hook data forwarded to the burn/mint, reconcile swaps and any trim.
    /// @param deadline      Tx reverts after this timestamp.
    struct RebalanceParams {
        uint256 tokenId;
        int128 additional0;
        int128 additional1;
        int24 newTickLower;
        int24 newTickUpper;
        bytes route;
        TokenAmount[] routeFunding;
        uint256 minLiquidity;
        address recipient;
        bytes hookData;
        uint256 deadline;
    }

    /// @notice Withdraw an existing position IN FULL and redeposit it into a new range, optionally adding to or
    ///         cashing out of each token, in one transaction. The position is always burned entirely; the
    ///         per-token redeploy budget is `withdrawn + additional` (the signed `additional0/additional1`), run
    ///         through the add flow (route + size + reconcile) into the new range. Any negative delta is returned
    ///         to `recipient`'s wallet up front. Always mints a NEW position (POSM ties a tokenId to a fixed range).
    /// @dev DESIGN NOTE — one signed knob for both add-more and cash-out: a rebalance is typically triggered by an
    ///      OUT-OF-RANGE position, whose liquidity earns nothing where it sits, so the whole position is withdrawn.
    ///      The signed deltas then let the caller redeploy exactly what they want: positive to top up from the
    ///      wallet, negative to peel a chosen amount back to the wallet, zero to redeploy the lot. Exact token
    ///      amounts (no basis-point rounding), and any mix of signs across the two tokens is allowed.
    ///
    ///      TRUST NOTE — operators: a POSM-approved operator can already withdraw the position's entire value
    ///      through POSM directly, so this contract grants an operator no new power; forcing an operator's output
    ///      to the owner is defense-in-depth, not the security boundary. Because the call is atomic, an honest
    ///      `minLiquidity` bounds the total cost of ANY route, so `route` is intentionally unrestricted. A
    ///      constrained operator system (e.g. a permissionless keeper contract) MUST therefore set `minLiquidity`
    ///      itself — value the position at the current price and convert all but the accepted cost of that value
    ///      into liquidity for the new range — and must never forward a caller-supplied `minLiquidity`.
    /// @return newTokenId The newly minted position id.
    function rebalance(RebalanceParams calldata params)
        external
        payable
        returns (uint256 newTokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @param tokenId           Position whose accrued fees to reinvest; caller must be owner or approved, and the
    ///                          contract must be approved on the position (POSM acts on the caller's behalf).
    /// @param route             Verbatim Universal Router payload for the surplus->deficit swap over the collected
    ///                          fees (may be empty; funding semantics as in `AddParams.route`). Size its input at
    ///                          the currently-unclaimed fees: accrual between quote and inclusion only adds to
    ///                          them and is absorbed by the same-pool reconcile; a competing fee collection makes
    ///                          the route's pull revert atomically.
    /// @param minLiquidityAdded Slippage floor: revert if the liquidity added by compounding < this.
    /// @param recipient         Receives any swept rounding dust (the fees themselves are reinvested, not paid out).
    ///                          Honored only when the caller is the owner; forced to the owner for an operator.
    ///                          The resolved recipient must not be this SwapAndAdd contract.
    /// @param hookData          Hook data forwarded to the fee collect, increase, reconcile swaps and any trim.
    /// @param deadline          Tx reverts after this timestamp.
    struct CompoundParams {
        uint256 tokenId;
        bytes route;
        uint256 minLiquidityAdded;
        address recipient;
        bytes hookData;
        uint256 deadline;
    }

    /// @notice Reinvest a position's accrued fees back INTO the same position, in one transaction. Collects the
    ///         fees (without touching principal), balances them to the position's current ratio — via the
    ///         optional `route` and/or the same-pool reconcile — and INCREASEs the same tokenId. The fees never
    ///         reach the caller's wallet (compounding) and the NFT is never moved — only the existing position
    ///         grows.
    /// @dev Equivalent to an `increase` with a zero pulled budget (the two share one execution path); kept as
    ///      its own endpoint for clarity and because it is non-payable. Operator trust model: see the TRUST
    ///      NOTE on `rebalance`. Constrained operator systems must likewise set `minLiquidityAdded` themselves
    ///      rather than forward a caller-supplied value.
    /// @return liquidityAdded The liquidity added to the position by reinvesting the fees.
    /// @return amount0        token0 reinvested into the position.
    /// @return amount1        token1 reinvested into the position.
    function compound(CompoundParams calldata params)
        external
        returns (uint128 liquidityAdded, uint256 amount0, uint256 amount1);
}
