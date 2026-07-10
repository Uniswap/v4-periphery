# SwapAndAdd — Audit Scope & Package

Branch: `feat/swap-and-add` (v4-periphery). Pin the audit to the head commit of this branch at handoff.
Solc `0.8.26`, EVM `cancun`. SwapAndAdd compiles under `via_ir = true, optimizer_runs = 500`
(`compilation_restrictions` in `foundry.toml`); runtime size 20,121 B (4,455 B margin to the 24,576 limit).

## 1. Scope

### In scope
| File | SLOC | Description |
|------|------|-------------|
| `src/SwapAndAdd.sol` | 521 | Route-first swap-and-add zap: add / increase / rebalance / compound |
| `src/interfaces/ISwapAndAdd.sol` | 67 | Interface + full user-facing semantics (NatSpec is normative) |
| `src/interfaces/external/IUniversalRouter.sol` | 5 | Minimal UR `execute` interface |

### Out of scope (audited separately / upstream)
- v4-core (`PoolManager`), v4-periphery `PositionManager` (POSM), Permit2 — prior audits in `audits/`.
- Universal Router — **but see §3: the routed path depends on an unmerged UR feature branch.**
- Test files, mocks, scripts.

## 2. What the contract does

One `PoolManager.unlock` per operation:

1. **ROUTE FIRST** — run the caller's verbatim Universal Router payload (surplus → deficit, a black box:
   it may even touch this pool — the post-route balances and pool price are simply the source of truth for
   every later step). Both pool tokens are funded for it; whatever it does not consume stays for step 3.
   Native value left in the UR is reclaimed via a UR `SWEEP` (UR balances are permissionlessly sweepable).
2. **SIZE & DEPLOY** — size liquidity from the *actual* post-route holdings at the live price, fee-aware
   (the side the same-pool reconcile will sell is discounted by that direction's total swap fee:
   `ProtocolFeeLibrary.calculateSwapFee(directional protocol fee, lpFee)`). Flash-`take` whichever side is
   short, then MINT a new position to this contract (add/rebalance) or INCREASE the existing tokenId
   (increase/compound).
3. **RECONCILE** — one same-pool swap in whichever direction is short, then a DECREASE ("trim") lands the
   position exactly on what the holdings support. The trim is capped at the liquidity added in step 2.
4. **FLOOR** — revert unless final (post-trim) liquidity ≥ `minLiquidity`. This is the single slippage gate.
5. **SWEEP** — leftovers to the recipient; add/rebalance transfer the NFT after the unlock closes.

Entrypoints: `add` (new NFT), `increase` (grow a tokenId in place), `rebalance` (full burn → new NFT, signed
top-up/cash-out deltas), `compound` (reinvest accrued fees into the same tokenId). ERC-20 + native ETH
(native is always `currency0`). No owner, no pause, no upgradeability, no stored funds.

## 3. External dependencies & trust assumptions

| Dependency | Role | Trust assumption |
|-----------|------|------------------|
| `PoolManager` | unlock, swap, take/settle | Fully trusted (v4-core) |
| `PositionManager` (POSM) | mint/increase/decrease via `modifyLiquiditiesWithoutUnlock` | Fully trusted; holds new NFTs transiently during add/rebalance |
| `Permit2` | pulls caller budgets; standing allowances from this contract | Fully trusted |
| `UniversalRouter` | executes caller-supplied route inside the unlock | Trusted code; **caller-controlled payload** (see K-02) |
| Pool tokens | standard ERC-20 or native | No fee-on-transfer, no rebasing (unsupported by design) |
| Hooks | pools may have hooks | Fee-taking hooks unsupported (see K-01) |

**⚠ Unmerged dependency:** the routed path requires the Universal Router branch
`feat/v4-swap-within-existing-unlock` (submodule `lib/universal-router` pinned at `cf27fb66e5`), which lets
`V4_SWAP` run inside an already-open `PoolManager` unlock. On the released UR, a nested `execute` with
`V4_SWAP` reverts `AlreadyUnlocked` (empty-route and non-v4 route legs are unaffected). The audit must either
include that UR delta or record it as an assumption; SwapAndAdd cannot ship to production before it merges.

## 4. Invariants

1. **No funds at rest.** Outside an active operation the contract holds no tokens, no native balance and no
   positions. Every entrypoint pulls the caller's budget, deploys/settles it in full and sweeps the remainder
   in the same transaction. Donations are simply absorbed into the next caller's budget. *This invariant is
   load-bearing for the standing allowances (K-03) — give it particular attention.*
2. **Trim never touches principal.** The reconcile trim is capped at the liquidity the current operation just
   added (`lopt`), so increase/compound can never consume the owner's pre-existing position; if `lopt` cannot
   cover the deficit, the unlock reverts (`CurrencyNotSettled`) instead.
3. **Operators cannot redirect value.** Only the position owner may name a custom recipient; for an approved
   operator, all output (new NFT, cash-out, swept dust) is forced to the owner. (Defense-in-depth: a
   POSM-approved operator could already withdraw via POSM directly, so this contract grants no new power.)
4. **Single slippage gate.** POSM per-amount limits are set to max and same-pool swaps carry no price limit;
   `minLiquidity` checked on the final position bounds the whole operation's cost atomically.
5. **Exact native accounting.** `msg.value` must equal the declared native budget/delta exactly
   (`InvalidEthValue`); `receive()` accepts only PoolManager/POSM/UR (`InvalidEthSender`); after a route, any
   native left in the UR is reclaimed before proceeding.
6. **Atomicity.** Any funding shortfall reverts the entire unlock — there is no partial-fill state.

The no-funds-at-rest and no-new-NFT/ownership properties are asserted throughout the unit suite
(`zap balance == 0` at the end of every test); invariants 2–5 each have dedicated tests.

## 5. Known issues & design decisions

- **K-01 — fee-taking hooks (Medium, accepted):** the reconcile relies on a conservation identity (the
  same-pool swap's output plus what the trim frees covers the flash-taken deficit). Hooks that skim swap
  output or withdrawal amounts break it; on such pools the call reverts atomically inside the unlock —
  funds are safe, but the operation can be unusable there. Documented in `ISwapAndAdd`.
- **K-02 — `route` is intentionally unrestricted, including for operators (accepted):** because the call is
  atomic, an honest `minLiquidity` bounds the total cost of ANY route. A constrained operator system (e.g.
  a permissionless keeper) MUST set `minLiquidity` itself and never forward a caller-supplied value —
  normative TRUST NOTE on `rebalance` in `ISwapAndAdd`.
- **K-03 — standing max Permit2 allowances to POSM and UR (accepted, review closely):** granted once per
  token (`_ensureApproved`) instead of bounded per-call allowances (saves an allowance write per operation).
  Safe *because* of invariant 1: both spenders only pull from their direct caller, i.e. only when this
  contract invokes them mid-operation, at which point its balance is the current caller's own budget and
  `minLiquidity` bounds the outcome.
- **K-04 — same-pool swaps have no `sqrtPriceLimit`:** input is bounded by the operation's own holdings and
  the outcome by `minLiquidity`. Exercised by the thin-pool and huge-single-sided tests.
- **K-05 — flash-take needs PoolManager-wide reserves of the deficit token (Low, accepted):** the optimistic
  deploy flash-`take`s the deficit from the PM's global balance. In the degenerate state where the PM holds
  ~none of that token (found by `test_add_priceExactlyOnLowerBoundary_tickAt` before its liquidity seed: a
  boundary swap had bought the entire token0 reserve), even a wei-level take reverts atomically. Requires the
  PM to be near-empty of a token across ALL pools — academic in production, funds safe.
- **D-01 — fee-on-transfer / rebasing tokens unsupported** (by design; sizing and settle math assume
  received == sent).
- **D-02 — native ETH only as `currency0`** (v4 sorts native first); `currency1` never consumes `msg.value`.
- **D-03 — two forge-lint `unsafe-typecast` warnings** (`uint256(-int256(delta))` in `_resolveBudget`,
  `uint256(-owed)` in `_reconcile`) are sign-guarded negations — false positives, left unsuppressed to match
  repo convention.
- **D-04 — ROUNDING_BUFFER = 1 wei** is flash-taken on the deficit side so POSM's round-up never under-funds
  the deploy; the excess returns via the trim/sweep path.

## 6. Build & test

```bash
forge build                        # default profile
forge test --match-path "test/SwapAndAdd*"        # 44 unit tests (incl. fuzz), mock route
FOUNDRY_PROFILE=integration forge test            # 15 tests: real UR route tests + mainnet fork
```

The integration profile compiles `test-integration/` with the real (via_ir-only) Universal Router from the
submodule. The mainnet fork suite defaults to a keyless public RPC at head; for a reproducible run set
`FORK_URL` to an archive endpoint and `FORK_BLOCK` (e.g. `25_495_000`, 2026-07-09).

Unit tests deploy SwapAndAdd from its precompiled via_ir/500 artifact via `deployCode` (the test unit itself
builds with `via_ir = false`), mirroring how the suite deploys POSM. **Consequence:** `forge coverage` cannot
attribute line hits to `src/SwapAndAdd.sol` (the instrumented source build is never the deployed bytecode) —
the same limitation applies to POSM in this repo. Coverage is argued functionally instead: every entrypoint,
every custom error, both reconcile directions, native + ERC-20 + no-return-token pools, operator/recipient
guards, thin-pool and range-edge extremes, and a two-sided fuzz are all exercised; the no-funds-at-rest
invariant is asserted at the end of every test.

## 7. Static analysis (slither, scoped to in-scope files)

10 raw results, triaged:

| Detector | Finding | Triage |
|----------|---------|--------|
| `unused-return` (1 of 7) | `IERC20Minimal.approve` return ignored in `_ensureApproved` | **Genuine, fixed**: a declared-`returns (bool)` approve reverts on decode for no-return tokens (USDT), bricking every pool of that token. Replaced with solmate `SafeTransferLib.safeApprove`; regression test `test_add_approveNoReturnToken`. |
| `unused-return` (6 of 7) | `getSlot0` partial destructuring; `poolManager.swap` return ignored | Intentional: accounting is delta-based — swap results are read back via `currencyDelta` (`_settleToward`/`_takeCredit`), not from the return value. |
| `reentrancy-no-eth` | state written after external calls across the two `_ensureApproved` calls | `_tokenApproved[token] = true` is written *before* that token's external calls (CEI holds per token); entrypoints are `ReentrancyLock`-guarded and the body runs inside the PoolManager unlock. Worst case is a redundant re-approval. |
| `uninitialized-local` (×2) | `expectedValue` in `_pullBudget` / `_pullAdditional` | Intentional default-0: only set when the native side has a positive budget/delta; `msg.value` must equal it exactly. |
