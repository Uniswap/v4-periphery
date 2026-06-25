---
description: Design & implement the SwapAndAdd v4 contract (interface-first), following the locked design
argument-hint: "[optional focus, e.g. AddParams | add flow | rebalance | tests]"
---

# SwapAndAdd (v4) — interface & implementation

You are helping build the **SwapAndAdd** contract in **this `v4-periphery` repo**, on a feature branch off `main` (NOT `margin-trading`). It is a **v4-only** liquidity zap that, in one transaction, takes a user's tokens (one of the pool tokens, or both in any ratio) and gives them a **standard PositionManager (POSM) ERC-721** position. Two flows: **add** (new position) and **rebalance** (withdraw an existing position → re-add into a new range).

**Focus for this session:** $ARGUMENTS
(If empty, start with the **interface** — the `AddParams` struct and the `add()` / `rebalance()` signatures — and confirm it with the user before implementing.)

## How to work
1. **Pin the interface first.** Propose/refine `AddParams` + function signatures, confirm with the user, *then* implement. Do not start the implementation until the struct is agreed.
2. **Follow the locked design below — do not re-litigate it.** It was converged over a long design discussion. If something seems wrong, raise it explicitly with reasoning, but default to building to this.
3. **TDD.** Write Foundry tests (use v4-core's `Deployers`). Test against the **real modified Universal Router** from the `universal-router` branch `feat/v4-swap-within-existing-unlock` (which lets a contract holding a v4 unlock delegate a full route to `UR.execute`). **Do not build a MockUniversalRouter** — use the real UR.
4. Verify every external assumption against the actual source in `lib/` before relying on it. Cite `file:line`.

## Locked v1 design — the single-mint flow
All inside one `PoolManager.unlock` callback where SwapAndAdd is the locker:

1. **Size L on-chain** from the user's budget at the slippage rate (value-conservation: `L = L_ref · budgetValue / refValue`, valuing at the worst-acceptable swap rate). The token *ratio* comes from range + live `slot0`; L is the magnitude.
2. **Flash-`take` the deficit `b`** and **mint the position directly to the USER** via `PositionManager.modifyLiquiditiesWithoutUnlock` (`owner = user`). Position is now locked at the live (pre-swap) price.
3. **Route swap (bulk):** call `UR.execute` with the off-chain-provided route, **run verbatim** — never patch/spoof its amounts. Best execution, any venue (v2/v3/v4 mixed).
4. **One same-pool reconcile swap** to repay exactly `b`: top up a shortfall (`A→B` exact-out) **or** sell excess `B→A` (price impact is irrelevant — we already minted). This guarantees leftover lands only in token A.
5. **Repay the `take`, sweep leftover A to the user.** Done.

One mint (to the user), one route swap, one same-pool swap. **No second mint, no `INCREASE`, no mint-to-self, no transfer, no iteration.**

## Hard invariants (must always hold)
- **No dust in the swapped-into token.** Excess B is always sold back to A on the same pool. Only token A is ever returned as leftover.
- **Leftover A = unused slippage = a benefit returned to the user.** That's expected and fine.
- **Slippage = a single off-chain `minLiquidity` floor.** Compute L on-chain from budget + live `slot0`, build the position, then `assert(finalLiquidity >= minLiquidity)` and revert otherwise. Do **NOT** use `minAmount0`/`minAmount1` (price-sensitive → false reverts on honest drift) or a separate swap-slippage param. The floor is the user's whole protection — it bounds bad execution AND adverse price drift in one number.
- **Frontrunning is bounded, not eliminated:** the floor caps extractable MEV at the tolerance (revert beyond it); within-band MEV is inherent to any AMM interaction. Full prevention = MEV-protected submission (frontend/RPC concern) — note this in integration docs.
- **No on-chain "output spoofing"** of the off-chain route. The route runs as encoded; the only on-chain-amount swap is our own native same-pool reconcile.
- **Mint-first ordering** (mint before swapping) — it makes the position immune to the swap's price impact and resolves the swap direction/amount from on-chain state (critical for partial rebalance).

## Architecture / dependencies
- **Standalone contract — NOT the Universal Router.** Inherit `SafeCallback` + `DeltaResolver` + `Permit2Forwarder` (`src/base/`).
- **Mint via** the canonical `PositionManager.modifyLiquiditiesWithoutUnlock(actions, params)` (`src/PositionManager.sol`).
- **Swap via** a minimal `IUniversalRouter { function execute(bytes commands, bytes[] inputs) external payable; }` interface + a constructor UR address. **Do not import UR source** (keeps the dependency direction clean).
- **UR funding:** grant a **bounded per-call Permit2 allowance** to UR (NOT a standing `type(uint160).max`); route uses `payerIsUser` so UR pulls from this contract, output back to this contract. Plus a **reentrancy guard** on `add()`/`rebalance()` and an **end-of-call zero-balance sweep** (the contract must never hold funds between txs). The route calldata is trusted (we trust UR fully); the contract bounds the *outcome* via the `minLiquidity` floor, not by validating route internals.
- Constructor immutables: `poolManager`, `positionManager`, `permit2`, `universalRouter`.
- Native ETH supported via `Currency`. Permissioned pools: out of scope for v1.
- Check `poolManager.isUnlocked()` is not needed here (we are the one unlocking); the UR-side branch handles its own check.

## Rebalance = reuse the add core
"Withdraw the old position (POSM decrease/burn — requires the contract be approved for the `tokenId`) → use the proceeds + fees as the starting budget → run the exact same add flow." Direction (which token is the deficit) falls out of the on-chain net after the mint.

## Out of scope for v1 (documented follow-ons — do NOT build unless asked)
- **Threshold-gated leftover deploy:** an optional `threshold`; if `> 0`, mint to the *contract* instead, run an extra same-pool "add-and-swap" (increase-first, single pass) to deploy leftover A, then transfer the NFT to the user **after the unlock closes** (POSM `transferFrom` requires the pool locked). If `threshold == 0`, mint directly to the user (the v1 path).
- v3 support (separate contract). Third-token ("floated") entry. Aperture closed-form math.

## Proposed starting interface (refine with the user first)
```solidity
struct AddParams {
    PoolKey poolKey;
    int24 tickLower;
    int24 tickUpper;
    Currency inputToken;      // or support a (amount0, amount1) budget for any-ratio input
    uint256 inputAmount;
    bytes route;              // off-chain UR route for the bulk swap, run verbatim
    uint256 minLiquidity;     // slippage floor: assert(finalLiquidity >= minLiquidity) or revert
    address recipient;        // receives the NFT and leftover A
    uint256 deadline;
}
function add(AddParams calldata p) external payable returns (uint256 tokenId);
// rebalance(...) mirrors this with a tokenId + new range + % to move; reuses the add core.
```
Open the session by interrogating this struct (single vs mixed-token budget, how `route` + `slippageTolerance` are encoded) and locking it with the user before writing `add()`.

## Key references (verify in `lib/`)
- POSM within-unlock mint: `src/PositionManager.sol:182` (`modifyLiquiditiesWithoutUnlock`), `:224`/`:369` (mints NFT to `owner`), `:385` (`validateMaxIn`), `:528-535` (`_pay` via Permit2 from the locker).
- `INCREASE` requires approval: `src/PositionManager.sol:295` (relevant only to the optional threshold follow-on).
- v4 lock / native unlock check: `lib/v4-core/src/PoolManager.sol`, `TransientStateLibrary.isUnlocked`.
- `LiquidityAmounts` rounds amounts **down**; POSM mint rounds **up** (≤1 wei) — carry a 1-wei buffer on the deficit `take`.
- UR within-unlock swap delegation: `universal-router` branch `feat/v4-swap-within-existing-unlock` (Dispatcher `V4_SWAP` → `_executeActionsWithoutUnlock` when `poolManager.isUnlocked()`).
