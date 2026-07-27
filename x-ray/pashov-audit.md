# Security Audit Report: Uniswap v4-periphery Margin Trading Suite

## 1. Executive Summary

| | |
|---|---|
| **Protocol** | Uniswap v4-periphery margin-trading suite — leveraged spot positions built as a single flash-style swap inside one v4 `PoolManager` unlock, backed by per-user soulbound `MarginAccount` clones and four curated lending adapters (Morpho Blue, Aave v3, Aave v4, Compound v3). |
| **Repository** | `/Users/chris.cashwell/dev/v4-periphery`, branch `margin-trading` |
| **Commit** | `e3d86dd2f8199e4265adf0579ba3af953aeb2a0b` |
| **Scope** | 1,326 nSLOC across 19 files (see Appendix A) |
| **Compiler** | Solidity 0.8.26, `via_ir`, `optimizer_runs = 44444444`, `evm_version = cancun` |
| **Deployment state** | **LIVE on Ethereum mainnet** (chain 1). Router `0x000000a16bfA211d163C244427acE70dD9014444`. TVL currently low (launch phase). |
| **Methodology** | Pashov-style parallelized 8-agent review (Appendix B), followed by an adversarial refutation pass on every candidate finding, followed by an independent citation re-verification of every line referenced in this report. |

### Findings summary

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 8 |
| Informational | 7 |
| Open leads (confidence < 75, unverified) | 6 |

### Honest assessment

**This codebase is in good shape.** Eight independent agent lenses produced exactly one finding that survived adversarial refutation, and that one was downgraded from High to Low because the mechanism is privileged-only, reversible in a single transaction, and does not put funds at risk. Five further candidates filed at High or Medium were refuted outright (Appendix C) — in every case because a real mitigating line existed that the reporting agent had not traced.

The reasons the attack surface holds up are structural, not incidental:

- **The active account is never calldata-derived.** Every path resolves it through `msgSender()` → `_getLocker()` (`src/MarginRouter.sol:381-383`), and the CREATE2 salt plus clone immutable args bind the owner (`src/MarginAccountFactory.sol:70-72`, `:80-82`). No agent found a cross-user path. This single decision eliminates the entire class of "hostile adapter / hostile hook reaches a victim's account" findings, which is why three separate agents' arbitrary-call reports all collapsed to Informational.
- **Amounts are measured, never trusted.** Balance deltas in `MarginAccount` (`src/MarginAccount.sol:78`, `:98`, `:115`) and PoolManager deltas in the router (`src/base/DeltaResolver.sol:60-76`) mean a short-delivering protocol produces a smaller number, not a silent loss. The checked subtraction at `src/MarginRouter.sol:248` turns "the flow consumed someone else's residual" into a revert.
- **Reads fail safe.** Every adapter returns `type(uint256).max` LTV when debt exists against zero collateral value, so a dead oracle reverts `ASSERT_HEALTH` rather than passing it.
- **The documentation is unusually good, and that is itself load-bearing.** Most of what remains in this report is documentation drift: comments that assert an invariant slightly stronger than the code enforces (L-03, I-01, I-05). That is a real defect class in a codebase whose safety argument is carried by its comments, but it is not a fund-loss class.

The two areas worth engineering attention before TVL grows: (1) the four `MarginAccount` primitives should enforce the `target == adapter.lendingProtocol()` and `value == 0` invariant that four separate specs already claim they enforce — the test hook for it was written and never wired up (L-03); and (2) the event payloads that the in-repo indexer treats as authoritative are venue-inconsistent or caller-influenceable in three places (L-02, L-05, L-08).

---

## 2. Findings

Severity follows the impact × likelihood matrix. Verdicts: **CONFIRMED** = survived a dedicated adversarial refutation attempt; **UNVERIFIED** = reported by an agent with a traced mechanism and re-verified citations, but no adversarial refutation pass was run against it.

### L-01 — Adapter-level per-market de-registration degrades or silently misreports the curated `decreasePosition` exit path for open positions

| | |
|---|---|
| **Severity** | Low (Impact: Medium — temporary loss of the guard-railed exit path; Likelihood: Unlikely — requires a privileged action against a pair with open positions) |
| **Type** | Logic / Governance blast radius |
| **Location** | [`src/MarginRouter.sol:171`](../src/MarginRouter.sol#L171) |
| **Agents** | [agents: 2/8] — `invariants` (survivor), `first-principles` (independent duplicate, filed variant refuted as overstated, see R-04) |
| **Verdict** | **CONFIRMED** (originally reported High; corrected to Low on refutation) |
| **Status** | Confirmed |

#### Description

`decreasePosition`'s first external read is unconditional and happens before the flow decides which branch to take:

```solidity
// src/MarginRouter.sol:170-171
account = accountOf(msgSender(), params.subId);
(uint256 collateralBefore, uint256 debt) = params.adapter.positionOf(account, params.market);
```

The debt-free full-close fast path is at `src/MarginRouter.sol:175`, *after* that read. So anything that makes `positionOf` revert takes the entire function down, including the branch that needs no swap.

For three of the four adapters, `positionOf` is gated by the adapter's own per-`(collateral, debt)` registry, which is owner-mutable at any time with no consideration of open positions:

- `AaveLendingAdapter.positionOf` (`src/AaveLendingAdapter.sol:185-195`) calls `_requireSupportedMarket` (`src/AaveLendingAdapter.sol:274-278`), driven by `_allowed[collateral][debt] = allowed;` at `src/AaveLendingAdapter.sol:268`.
- `CompoundV3LendingAdapter.positionOf` (`src/CompoundV3LendingAdapter.sol:186-194`) calls `_requireSupportedMarket` (`src/CompoundV3LendingAdapter.sol:302-306`), driven by `src/CompoundV3LendingAdapter.sol:296`.
- `AaveV4LendingAdapter.positionOf` (`src/AaveV4LendingAdapter.sol:207-215`) calls `_resolveRoute` (`src/AaveV4LendingAdapter.sol:327-330`), which reverts on `!route.registered` — and `setMarket(..., allowed = false)` executes `delete _routes[collateral][debt];` at `src/AaveV4LendingAdapter.sol:318`.

Morpho has the mirror-image variant. `MarketRegistry.register` is an unconditional overwrite (`src/types/MarketRegistry.sol:36-39`), and `MorphoLendingAdapter.setMarket` (`src/MorphoLendingAdapter.sol:230-243`) will happily re-point an already-used `(collateral, debt)` key at a **different** `MarketParams` (different oracle / IRM / LLTV, therefore a different Morpho market `Id`). After that, `resolve` no longer reverts (`src/types/MarketRegistry.sol:47-52` only rejects a fully-zero entry), so `positionOf` (`src/MorphoLendingAdapter.sol:144-152`) reads `morpho.position(newId, account)` — an `Id` the account never touched — and returns `(0, 0)`. `decreasePosition` then takes the debt-free branch at `src/MarginRouter.sol:175-193` and emits `PositionDecreased` reporting the position as fully closed with nothing withdrawn, while the real collateral and debt remain under the old market `Id`.

The tension is with the router's own documented guarantee. `src/interfaces/IMarginRouter.sol:267-271` states that "a position can always be delevered or closed even if its adapter is later removed from the allowlist", and `src/MarginRouter.sol:567-568` states withdraw/repay are "Not allowlist-gated: a position must always be exitable." Both statements are true **of the router's `_allowedAdapters` allowlist** — `_requireAllowedAdapter` genuinely never appears in `decreasePosition` (its only call sites are `src/MarginRouter.sol:294`, `:421`, `:560`, `:575`). Neither statement scopes the *adapter's own* per-pair registry, which is a second, independent gate consulted by every adapter function including pure reads.

No test covers this. `test/lending/AaveLendingAdapter.t.sol:271-275` asserts only that `isSupportedMarket` goes false after a disable; no test disables a pair with a live position and then attempts a close.

#### Impact

A single owner transaction on an adapter (not the router) removes the curated close/decrease path for every open position on that market pair. The trigger is a plausible, non-malicious operational action: deprecating a market, reacting to an oracle concern, or migrating a Morpho market to a new oracle/IRM.

Bounded by four factors, which is why this is Low and not High:

1. **Fully reversible in one transaction by the same actor.** `src/AaveLendingAdapter.sol:268` and `src/CompoundV3LendingAdapter.sol:296` are plain boolean assignments; `src/AaveV4LendingAdapter.sol:314-316` re-writes the route; `src/MorphoLendingAdapter.sol:234` re-registers any `MarketParams`. Nothing is destroyed — the collateral and debt live in Aave/Morpho/Comet, untouched.
2. **Funds remain recoverable with no governance action at all.** `lendingProtocol()` is the one adapter function with no registry gate (`src/AaveLendingAdapter.sol:105-107`, `src/AaveV4LendingAdapter.sol:133-135`, `src/CompoundV3LendingAdapter.sol:108-110`, `src/MorphoLendingAdapter.sol:68-70`), and the owner-only escape hatch resolves its target through exactly that function (`src/MarginAccount.sol:135-136`). `src/interfaces/IMarginAccount.sol:138-140` documents this as the intended last resort: "the owner can always close a position or recover funds without involving the manager."
3. **Reverting reads on unrouted pairs are deliberate**, documented at `src/AaveLendingAdapter.sol:46-47` and `src/interfaces/ILendingAdapter.sol:18-20`.
4. **The Morpho silent-close variant is recoverable offchain**: `MorphoLendingAdapter.setMarket` emits `MarketSet` with the full `MarketParams` including `id`, `oracle`, `irm`, `lltv` on every registration (`src/MorphoLendingAdapter.sol:235-242`), so the prior market is reconstructible from event history. And `src/MarginRouter.sol:185-188` emits explicit zeros for `debtRepaid`/`collateralWithdrawn` rather than fabricating a nonzero withdrawal.

Residual real harm: a user must hand-craft protocol calldata for `MarginAccount.execute` during the window, and an indexer trusting a Morpho `PositionDecreased` would mark a live position closed. The only economic loss scenario requires a liquidation to land inside the disabled window — owner negligence plus adverse price movement.

#### Exploit path

1. A user opens a position on the live Aave v3 USDC-collateral / WETH-debt market.
2. The adapter owner calls `AaveLendingAdapter.setMarket(USDC, WETH, false)` (`src/AaveLendingAdapter.sol:261-270`) for an operational reason.
3. The user calls `decreasePosition` (partial or full). `src/MarginRouter.sol:171` calls `positionOf`, which reverts `MarketNotSupported` before the branch at `:175` is reached — so even a debt-free close, which needs no swap and no allowlist, is unreachable.
4. The user must instead call `MarginAccount.execute` (`src/MarginAccount.sol:128-138`) with hand-built `IPool.repay` / `IPool.withdraw` calldata. The adapter's own `encodeRepay`/`encodeWithdrawCollateral` helpers are equally gated (`src/AaveLendingAdapter.sol:171`, `:139`), so they cannot be used to build it.
5. Morpho variant: the owner calls `setMarket` with a new `MarketParams` for the same pair (`src/MorphoLendingAdapter.sol:230-243`); a subsequent `decreasePosition` succeeds, does nothing, and emits a full-close event.

#### Recommendation

The cheapest correct fix is to make de-registration position-aware rather than to restructure the exit path. Add a state-changing guard so governance cannot silently strand positions:

```solidity
// Before (src/AaveLendingAdapter.sol:261-270) — unconditional, position-blind
function setMarket(Currency collateral, Currency debt, bool allowed) external {
    _onlyOwner();
    if (allowed) { /* reserve validation */ }
    _allowed[collateral][debt] = allowed;
    emit MarketSet(Currency.unwrap(collateral), Currency.unwrap(debt), allowed);
}

// After — disabling stops NEW exposure but never breaks reads/exits
mapping(Currency collateral => mapping(Currency debt => bool)) internal _everAllowed;

function setMarket(Currency collateral, Currency debt, bool allowed) external {
    _onlyOwner();
    if (allowed) {
        /* reserve validation */
        _everAllowed[collateral][debt] = true;
    }
    _allowed[collateral][debt] = allowed;
    emit MarketSet(Currency.unwrap(collateral), Currency.unwrap(debt), allowed);
}

/// gate exposure-INCREASING encoders on `_allowed`
function _requireSupportedMarket(Market calldata market) internal view {
    if (!_allowed[market.collateral][market.debt]) {
        revert MarketNotSupported(market.collateral, market.debt);
    }
}

/// gate reads and EXIT encoders on the append-only historical set, mirroring the
/// router's own allowlist asymmetry one level down
function _requireRoutableForExit(Market calldata market) internal view {
    if (!_everAllowed[market.collateral][market.debt]) {
        revert MarketNotSupported(market.collateral, market.debt);
    }
}
```

Apply `_requireRoutableForExit` in `positionOf`, `describePosition`, `currentLtvWad`, `encodeRepay`, and `encodeWithdrawCollateral`; keep `_requireSupportedMarket` on `encodeSupplyCollateral` and `encodeBorrow`. For `AaveV4LendingAdapter`, stop `delete`-ing the route (`src/AaveV4LendingAdapter.sol:318`) and instead clear only the `registered` flag while retaining the reserve ids, so the exit encoders can still resolve them.

For Morpho specifically, prevent the silent re-point: make `setMarket` revert if a *different* `Id` is already registered for the same `(collateral, debt)` key, and require an explicit `migrateMarket` call that emits a distinct event.

At minimum (if no code change is accepted), correct `src/interfaces/IMarginRouter.sol:267-271` and `src/MarginRouter.sol:567-568` to scope the guarantee to the *router* allowlist, and publish a per-venue `MarginAccount.execute` recovery recipe.

---

### L-02 — `withdrawCollateral`'s measured-delta forward is dead code on 3 of 4 adapters, so `CollateralWithdrawn.amount` and the return value are always zero for Morpho, Aave v3, and Compound v3

| | |
|---|---|
| **Severity** | Low (Impact: Low — offchain accounting correctness; Likelihood: Certain — every withdrawal on 3 of 4 live venues) |
| **Type** | Integration / Event accounting |
| **Location** | [`src/MarginAccount.sol:74`](../src/MarginAccount.sol#L74) |
| **Agents** | [agents: 1/8] — `periphery` |
| **Verdict** | **UNVERIFIED** (mechanism traced, citations re-verified; no adversarial pass) |
| **Status** | Confirmed |

#### Description

`MarginAccount.withdrawCollateral` measures the amount it forwards as its own balance increase across the protocol call, and forwards only that:

```solidity
// src/MarginAccount.sol:74-80
uint256 balanceBefore = market.collateral.balanceOfSelf();
(address target, uint256 value, bytes memory callData) =
    adapter.encodeWithdrawCollateral(address(this), market, amount, to);
_execCall(target, value, callData);
withdrawn = market.collateral.balanceOfSelf() - balanceBefore;
if (withdrawn != 0) market.collateral.transfer(to, withdrawn);
emit CollateralWithdrawn(msg.sender, address(adapter), market.collateral, withdrawn, to);
```

Three of the four adapters encode a receiver into the protocol call, so the account is never a transfer party and the delta is exactly zero:

- `src/MorphoLendingAdapter.sol:103` → `withdrawCollateral(marketParams, amount, account, receiver)`.
- `src/AaveLendingAdapter.sol:142` → `IPool.withdraw(collateral, amount, receiver)`; `src/interfaces/external/aave/IPool.sol:16-23` documents that it sends the underlying to `to`.
- `src/CompoundV3LendingAdapter.sol:147` → `IComet.withdrawTo(receiver, collateral, amount)`; `src/interfaces/external/compound-v3/IComet.sol:52-53` documents delivery to `to`.

Only `AaveV4LendingAdapter` drops the receiver (`src/AaveV4LendingAdapter.sol:166`, unnamed `address` parameter) and encodes `withdraw(reserveId, amount, account)` at `src/AaveV4LendingAdapter.sol:173`, because `ISpoke.withdraw` pays `msg.sender` (`src/interfaces/external/aave-v4/ISpoke.sol:96-106`). So the forward at `src/MarginAccount.sol:79` only ever fires on Aave v4.

The interface docs already half-acknowledge this — `src/interfaces/IMarginAccount.sol:100-102` says the return is "Zero when the lending protocol delivers the withdrawal directly to `to`" — but `src/interfaces/IMarginAccount.sol:41` documents the *event field* as "The amount forwarded to `to`, measured as the account's balance increase", so the same field means "the amount withdrawn" on one venue and a hardcoded zero on three.

#### Impact

No fund loss: the router discards the return value at `src/MarginRouter.sol:177` and `src/MarginRouter.sol:570`, and derives real amounts from `positionOf` / `describePosition`. The impact is entirely on offchain consumers. This repo ships an indexer, and any consumer summing `CollateralWithdrawn.amount` reports **zero collateral outflow for the Morpho, Aave v3, and Compound v3 venues** — i.e. silently wrong position accounting and broken withdrawal monitoring on 3 of the 4 live venues.

#### Exploit path

Not adversarial; a correctness defect reachable on every withdrawal.

1. Open a Morpho WETH/USDC position via `increasePosition`.
2. Call `decreasePosition` with `debtToRepay = type(uint256).max`.
3. The plan runs `ACCOUNT_WITHDRAW_COLLATERAL` with `to = address(this)` (`src/MarginRouter.sol:233-238`); the account executes Morpho `withdrawCollateral(..., receiver = router)`.
4. Morpho transfers collateral from itself to the router. The account's balance never changes, so `withdrawn == 0` at `src/MarginAccount.sol:78` and the forward at `:79` is skipped.
5. `CollateralWithdrawn` is emitted with `amount = 0` even though the entire collateral position left the account.

#### Recommendation

Measure the recipient's delta instead of the account's — correct for both delivery styles with no per-venue branching:

```solidity
// Before (src/MarginAccount.sol:74-80)
uint256 balanceBefore = market.collateral.balanceOfSelf();
(address target, uint256 value, bytes memory callData) =
    adapter.encodeWithdrawCollateral(address(this), market, amount, to);
_execCall(target, value, callData);
withdrawn = market.collateral.balanceOfSelf() - balanceBefore;
if (withdrawn != 0) market.collateral.transfer(to, withdrawn);
emit CollateralWithdrawn(msg.sender, address(adapter), market.collateral, withdrawn, to);

// After — measure what `to` actually received, whoever delivered it
uint256 selfBefore = market.collateral.balanceOfSelf();
uint256 toBefore = market.collateral.balanceOf(to);
(address target, uint256 value, bytes memory callData) =
    adapter.encodeWithdrawCollateral(address(this), market, amount, to);
_execCall(target, value, callData);
uint256 held = market.collateral.balanceOfSelf() - selfBefore;
if (held != 0) market.collateral.transfer(to, held);
withdrawn = market.collateral.balanceOf(to) - toBefore;
emit CollateralWithdrawn(msg.sender, address(adapter), market.collateral, withdrawn, to);
```

Note the `to == address(this)` case (the router calling with `to = router`) is unaffected because `to` is never the account itself — `_requireReceiver` (`src/MarginAccount.sol:163-165`) constrains it to owner or manager.

Alternatively, uniformly deliver to the account and forward (encode the account as receiver in the Morpho / Aave v3 / Comet encoders, mirroring `encodeBorrow`), which also removes the adapter's ability to encode a receiver at all and thereby closes half of L-03. At absolute minimum, fix `src/interfaces/IMarginAccount.sol:41` to state the field is zero on receiver-passing venues.

---

### L-03 — `MarginAccount` never enforces the `target == adapter.lendingProtocol()` / `value == 0` invariant that four separate specs declare it enforces

| | |
|---|---|
| **Severity** | Low (Impact: Low today — capability is confined to the caller's own account and is subsumed by the accepted owner escape hatch; Likelihood: Certain — the check is simply absent) |
| **Type** | Access control / Unenforced invariant |
| **Location** | [`src/MarginAccount.sol:183`](../src/MarginAccount.sol#L183) |
| **Agents** | [agents: 3/8] — `execution-trace`, `vector-scan`, `periphery` (three independent reports of the same gap; two escalated variants at Medium/High were refuted, see R-02 and R-03) |
| **Verdict** | **UNVERIFIED** (mechanism traced, citations re-verified; the *escalated* variants of this same gap were adversarially refuted and downgraded to exactly this severity) |
| **Status** | Confirmed |

#### Description

Four specs state that the account constrains the call target and the call value:

- `src/MarginAccount.sol:26-27`: the account "routes every call to the adapter's declared `lendingProtocol()`, and performs a regular call (never a delegatecall)".
- `src/MarginAccount.sol:177-179`: `_execCall`'s NatSpec names the target as "the adapter's `lendingProtocol()`" and value as "zero for the standard non-payable lending calls, and the account holds no native balance to forward".
- `src/interfaces/ILendingAdapter.sol:36`, `:51`, `:66`, `:82`: "`@return target` The call target (always `lendingProtocol()`)"; and `:37-38`: "Always 0 for Morpho (non-payable); the account treats non-zero as a bug."
- `src/interfaces/IMarginRouter.sol:270`: "the MarginAccount itself constrains the call target, receiver, and value regardless of the adapter."

The code enforces none of it. All four manager-driven primitives take `(target, value, callData)` verbatim from the adapter and pass them straight through:

```solidity
// src/MarginAccount.sol:52-56   supplyCollateral
(address target, uint256 value, bytes memory callData) =
    adapter.encodeSupplyCollateral(address(this), market, amount);
_setApproval(market.collateral, target, amount);   // approves the UNVALIDATED target
_execCall(target, value, callData);
_setApproval(market.collateral, target, 0);

// src/MarginAccount.sol:109-114  repay
(address target, uint256 value, bytes memory callData) = adapter.encodeRepay(address(this), market, amount);
uint256 balanceBefore = market.debt.balanceOfSelf();
uint256 approveAmount = amount == type(uint256).max ? balanceBefore : amount;
_setApproval(market.debt, target, approveAmount);  // full debt-token balance on a max repay
_execCall(target, value, callData);

// src/MarginAccount.sol:182-183  no target or value check anywhere
function _execCall(address target, uint256 value, bytes memory callData) internal returns (bytes memory) {
    return Address.functionCallWithValue(target, callData, value);
}
```

`withdrawCollateral` (`src/MarginAccount.sol:75-77`) and `borrow` (`src/MarginAccount.sol:96-97`) are the same. The *only* place `lendingProtocol()` is read is the owner-only escape hatch at `src/MarginAccount.sol:135`.

Two secondary observations that compound it:

- The `value == 0` half became newly relevant in this very commit. `src/MarginAccount.sol:179` asserts "the account holds no native balance to forward", which stopped being true when `receive() external payable {}` was added at `src/MarginAccount.sol:187` (commit `e3d86dd`). The comment is now stale and an adapter-supplied non-zero `value` is spendable.
- The receiver half of the `IMarginRouter.sol:270` claim *is* enforced (`_requireReceiver`, `src/MarginAccount.sol:163-165`) and `onBehalf` is enforced (`address(this)` at `:53`, `:76`, `:96`, `:109`) — it is specifically the target and value halves that are absent.

**Corroborating evidence that this check was intended and lost:** `test/mocks/MockLendingAdapter.sol:19-21` defines `forcedTarget` with the comment "when set non-zero, encode\* returns this instead of lendingProtocol (to exercise the account's `target == lendingProtocol()` check)", routed through `_callTarget()` at `:31-33` into every encoder. `setForcedTarget` (`:27-29`) is never called by any test in the suite — grep across `test/` returns only its own definition.

Reachability with a caller-supplied, non-allowlisted adapter is real, because the allowlist is deliberately asymmetric (accepted design decision #5): `ACCOUNT_WITHDRAW_COLLATERAL` (`src/MarginRouter.sol:563-570`) and `ACCOUNT_REPAY` (`src/MarginRouter.sol:578-580`) carry no `_requireAllowedAdapter`, and `decreasePosition` has none anywhere in `src/MarginRouter.sol:155-284`.

#### Impact

**No fund loss and no third-party exposure today.** Every path that reaches these primitives resolves the account from the authenticated caller (`src/MarginRouter.sol:170`, `:295`, `:423`, `:540`), so the only account an unvetted adapter can drive is the caller's own — and that caller is the account's soulbound owner, who already holds a strictly more powerful primitive in `MarginAccount.execute` (`src/MarginAccount.sol:128-138`, accepted design decision #2). Every `ILendingAdapter` function is also `view` (`src/interfaces/ILendingAdapter.sol:40-127`), so Solidity emits `STATICCALL` and a hostile adapter cannot reenter.

The impact is the **loss of a stated defense-in-depth layer** that the rest of the design leans on:

- An ERC-20 approval is live on an adapter-chosen address at call time (`src/MarginAccount.sol:54`, `:112`) — on a max repay, for the account's entire debt-token balance.
- Native value is forwarded unchecked, now that the account can hold native.
- One bad governance allowlist entry escalates from "can misroute inside one lending protocol" to "arbitrary call plus arbitrary approval on every account", because allowlisted adapters *are* reachable against every user's account via `ACCOUNT_SUPPLY_COLLATERAL` / `ACCOUNT_BORROW`.
- Any future change that lets a party other than the account owner choose the adapter — a keeper/liquidator role, a manager-driven rebalance, a governance-set default adapter, or a second manager contract — converts this into arbitrary-call-as-victim's-account with **no change to `MarginAccount`**.

#### Exploit path

Demonstrating the missing check (the actor operates on their own account, which is why this is Low):

1. Deploy `EvilAdapter` implementing `ILendingAdapter` with all functions `view`. Its `encodeRepay(account, market, amount)` returns `(target = anyAddress, value = anyAmount, callData = anyBytes)`.
2. Call `MarginRouter.execute` with plan `[SET_ACCOUNT(subId), ACCOUNT_REPAY(EvilAdapter, market, 1)]`.
3. Dispatch reaches `src/MarginRouter.sol:578-580` with no `_requireAllowedAdapter` gate, calling `IMarginAccount(account).repay(EvilAdapter, market, 1)`.
4. `src/MarginAccount.sol:109` obtains the tuple from `EvilAdapter`; `:112` grants `target` an allowance on `market.debt`; `:113` executes the adapter-chosen target with adapter-chosen calldata and value via `Address.functionCallWithValue`. No comparison against `EvilAdapter.lendingProtocol()`; no `value == 0` check.
5. Same reachability via `ACCOUNT_WITHDRAW_COLLATERAL` (`src/MarginRouter.sol:570`) and via `decreasePosition`'s zero-debt branch (`src/MarginRouter.sol:177`), the latter with no `PoolManager` unlock at all.

#### Recommendation

Enforce in `MarginAccount` what the interfaces promise, so the guarantee does not depend on adapter honesty or on who selected the adapter. Keep the value-bearing path exclusively in the owner-only `execute`, which already resolves the target correctly.

```solidity
// Before (src/MarginAccount.sol:182-184)
function _execCall(address target, uint256 value, bytes memory callData) internal returns (bytes memory) {
    return Address.functionCallWithValue(target, callData, value);
}

// After — add errors to IMarginAccount, then:
error TargetNotLendingProtocol(address target);
error NonZeroCallValue(uint256 value);

/// @notice Validates an adapter-encoded call tuple against the invariant ILendingAdapter declares:
///         the target is always `lendingProtocol()` and the value is always zero.
function _requireProtocolCall(ILendingAdapter adapter, address target, uint256 value) internal view {
    if (target != adapter.lendingProtocol()) TargetNotLendingProtocol.selector.revertWith(target);
    if (value != 0) NonZeroCallValue.selector.revertWith(value);
}
```

Call it immediately after each `adapter.encode*` and **before** `_setApproval`, in all four primitives. For example:

```solidity
// src/MarginAccount.sol:47-59  supplyCollateral, after
function supplyCollateral(ILendingAdapter adapter, Market calldata market, uint256 amount)
    external
    returns (uint256)
{
    _authCaller();
    (address target, uint256 value, bytes memory callData) =
        adapter.encodeSupplyCollateral(address(this), market, amount);
    _requireProtocolCall(adapter, target, value);   // <-- added
    _setApproval(market.collateral, target, amount);
    _execCall(target, value, callData);
    _setApproval(market.collateral, target, 0);
    emit CollateralSupplied(msg.sender, address(adapter), market.collateral, amount);
    return amount;
}
```

Then wire `MockLendingAdapter.setForcedTarget` (`test/mocks/MockLendingAdapter.sol:27`) into a negative test for each of the four primitives — the hook already exists and has never been exercised.

Separately, correct the now-stale claim at `src/MarginAccount.sol:178-179` ("the account holds no native balance to forward"), which `receive()` at `src/MarginAccount.sol:187` invalidated.

---

### L-04 — `CompoundV3LendingAdapter.describePosition` guards division by the raw debt amount but divides by the USD debt *value*, panicking on dust debt

| | |
|---|---|
| **Severity** | Low (Impact: Low — escapable self-inflicted DoS, no fund loss; Likelihood: Unlikely — not reachable on the live USDC-base deployment) |
| **Type** | Math / Division-by-zero guard on the wrong variable |
| **Location** | [`src/CompoundV3LendingAdapter.sol:236`](../src/CompoundV3LendingAdapter.sol#L236) |
| **Agents** | [agents: 1/8] — `math-precision` (locally reproduced with a throwaway Foundry test against `test/mocks/MockComet.sol`, since removed) |
| **Verdict** | **UNVERIFIED** (mechanism traced and locally reproduced by the reporting agent; citations re-verified; no adversarial pass) |
| **Status** | Confirmed |

#### Description

The zero guard and the divisor are two different variables:

```solidity
// src/CompoundV3LendingAdapter.sol:227-238
uint256 debt = comet.borrowBalanceOf(account);
uint256 collateralValue = _usd(collateral, comet.getPrice(info.priceFeed), info.scale);
uint256 debtValue = _usd(debt, comet.getPrice(comet.baseTokenPriceFeed()), comet.baseScale());
data = PositionData({
    ...
    healthFactorWad: debt == 0                                    // guard on the RAW amount
        ? type(uint256).max
        : Math.mulDiv(collateralValue, info.liquidateCollateralFactor, debtValue)   // divide by the VALUE
});
```

`debtValue` is `mulDiv(debt, price, baseScale)` (`src/CompoundV3LendingAdapter.sol:265-267`), which truncates to zero whenever `debt * price < baseScale`.

On the live cUSDCv3 market this is unreachable: `baseScale = 1e6`, `price ≈ 1e8`, so `debtValue ≈ 100 * debt` and any nonzero debt yields a nonzero value. But the adapter binds an *arbitrary* Comet at construction with no base-scale validation (`src/CompoundV3LendingAdapter.sol:100-105`), and its own notes invite deploying another instance per base (`src/CompoundV3LendingAdapter.sol:27-28`: "To serve a different base, deploy another adapter against that Comet"). On a Comet whose base is an 18-decimal asset priced near 1e8 — the cWETHv3 shape, `baseScale = 1e18` with a constant 1e8 ETH/ETH base feed — `debtValue = debt / 1e10`, so any borrow below `1e10` wei makes `debtValue == 0`.

`Math.mulDiv(x, y, 0)` then panics `0x12`: with `prod1 == 0` the function returns `prod0 / denominator` (`lib/v4-core/lib/openzeppelin-contracts/contracts/utils/math/Math.sol:136-141`), and the comment on `:137` notes explicitly that "Solidity will revert if denominator == 0".

Secondary effect in the same state: `_ltv` (`src/CompoundV3LendingAdapter.sol:274-277`) returns `toLtv(mulDiv(0, WAD, collateralValue)) == 0`, so `currentLtvWad` reports a dust-debt position as debt-free and an `ASSERT_HEALTH` bound passes trivially.

#### Impact

On any Comet instance whose base amount can round to zero USD value, `describePosition` reverts with a raw arithmetic panic. The router calls it after the unlock in `increasePosition` (`src/MarginRouter.sol:129`), `addCollateral` (`src/MarginRouter.sol:313`), and the partial-decrease branch (`src/MarginRouter.sol:269`), so the whole operation reverts for a position whose base debt is dust. Notably, a partial decrease that *would leave* dust debt fails with an uninformative panic. No funds are lost — a full close never reads `describePosition` (`src/MarginRouter.sol:254-267` hardcodes its result) — so the impact is an escapable DoS. Not reachable on the currently live USDC-base deployment.

#### Exploit path

1. Deploy `CompoundV3LendingAdapter` against a Comet whose base is an 18-decimal asset with an ~1e8 base price feed (`baseScale = 1e18`).
2. Open a position, then partially decrease so the remaining base borrow is `< 1e10` wei.
3. `debt != 0`, so the guard at `src/CompoundV3LendingAdapter.sol:236` is skipped, but `debtValue = mulDiv(debt, 1e8, 1e18) == 0`.
4. `Math.mulDiv(collateralValue, liquidateCollateralFactor, 0)` panics `0x12`, taking `increasePosition` / `addCollateral` / the partial decrease with it.

#### Recommendation

Guard on the divisor, so the two branches agree with `_ltv`:

```solidity
// Before (src/CompoundV3LendingAdapter.sol:236-238)
healthFactorWad: debt == 0
    ? type(uint256).max
    : Math.mulDiv(collateralValue, info.liquidateCollateralFactor, debtValue)

// After
healthFactorWad: debtValue == 0
    ? type(uint256).max
    : Math.mulDiv(collateralValue, info.liquidateCollateralFactor, debtValue)
```

Optionally also reject the ambiguous state at construction, so `currentLtvWad` cannot report a dust-debt position as debt-free:

```solidity
// src/CompoundV3LendingAdapter.sol:100-105, after
constructor(IComet comet_, address owner_) OwnableAdapter(owner_) {
    address base = comet_.baseToken();
    if (base == address(0)) revert ZeroAddress();
    // a base scale above the 1e8 Comet price scale lets a nonzero base debt round to zero USD value
    if (comet_.baseScale() > 1e8) revert BaseScaleExceedsPriceScale(comet_.baseScale());
    comet = comet_;
    baseToken = base;
}
```

---

### L-05 — `poolKey.hooks`/`fee`/`tickSpacing` are unvalidated, so the entry and exit prices reported by the `Position*` events are fully caller-controlled

| | |
|---|---|
| **Severity** | Low (Impact: Low — offchain data integrity, no onchain fund risk; Likelihood: Possible — free to execute, requires deploying a hook) |
| **Type** | Logic / Oracle and data integrity |
| **Location** | [`src/types/Market.sol:70`](../src/types/Market.sol#L70) |
| **Agents** | [agents: 1/8] — `first-principles` |
| **Verdict** | **UNVERIFIED** (mechanism traced, citations re-verified; no adversarial pass) |
| **Status** | Confirmed |

#### Description

`Market.toSwapParams` is described as "The single choke point that reconciles a v4 pool with this market" (`src/types/Market.sol:45-50`), but it validates only two things:

```solidity
// src/types/Market.sol:69-76
// the pool must trade exactly this market's two currencies (order-independent)
if (!hasCurrencies(self, key.currency0, key.currency1)) revert MarketSwapMismatch();
// the swap input must be one of the market's currencies
if (!(input == self.collateral || input == self.debt)) revert MarketSwapMismatch();
params = SwapParams({
    zeroForOne: input == key.currency0, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96
});
```

`key.fee`, `key.tickSpacing`, and critically `key.hooks` are never constrained. `params.poolKey` is caller-supplied in both `IncreaseParams` (`src/interfaces/IMarginRouter.sol:187`) and `DecreaseParams` (`src/interfaces/IMarginRouter.sol:224`) and is passed through verbatim at `src/MarginRouter.sol:457` and `src/MarginRouter.sol:219`.

The *security* consequence is bounded — a caller-chosen hook cannot reach another user, and cannot exceed `amountInMaximum` (`src/V4Router.sol:144`) or defeat `ASSERT_FILL` (`src/MarginRouter.sol:543-549`); see Appendix D. The *data* consequence is not. `PositionIncreased.collateralBought` is `params.collateralToBuy` (`src/MarginRouter.sol:136`) and `debtDrawn` is `position.debtAmount - debtBefore` (`src/MarginRouter.sol:137`), both of which the caller influences by choosing a pool. A caller can initialize their own pool over the same currency pair with a hook that returns an arbitrary `BeforeSwapDelta`, and produce any `debtDrawn / collateralBought` ratio they like, at zero cost, while still opening a genuine leveraged position on the real lending market.

The interface instructs integrators to treat these numbers as a price: `src/interfaces/IMarginRouter.sol:66-67` says "the entry price is `debtDrawn / collateralBought` in the market's native decimals". The in-repo indexer does exactly that — `indexer/src/router.ts:89` computes `const priceX18 = collateralBought > 0n ? (debtDrawn * WAD) / collateralBought : null;` and folds it into `avgEntryPriceX18`.

#### Impact

Any offchain system that derives price, PnL, volume, or notional from the `Position*` events is manipulable for free: fabricated entry prices, fabricated realized PnL, fabricated leaderboard standings, and inflated or deflated volume for incentive programs. No onchain funds are at risk — the lending protocols price against their own oracles, and `maxDebtIn` / `maxCollateralIn` still bound the caller's own execution — so this is a data-integrity rather than a solvency issue. It does, however, silently invalidate the indexer's stated design.

#### Exploit path

1. Attacker deploys `FakeHook` with `beforeSwap` permissions and initializes a v4 pool `(USDC, WETH, fee = anything, tickSpacing = anything, hooks = FakeHook)`. Both currencies match the live Morpho WETH-collateral/USDC-debt market, so `hasCurrencies` at `src/types/Market.sol:70` passes.
2. Attacker calls `increasePosition` with that `poolKey`, the real allowlisted `MorphoLendingAdapter`, `collateralToBuy = 100 WETH`, and a generous `maxDebtIn`.
3. `FakeHook.beforeSwap` returns a `BeforeSwapDelta` that fills the exact-output request for an arbitrarily small input (the hook funds the difference, or nets it back to itself out of band).
4. `ASSERT_FILL` (`src/MarginRouter.sol:543-549`) passes on the router's real credit; `TAKE`, `ACCOUNT_SUPPLY_COLLATERAL`, `ACCOUNT_BORROW`, `SETTLE` all proceed normally against Morpho. A real 100 WETH collateral position opens with a tiny recorded debt draw.
5. `PositionIncreased` reports `collateralBought = 100e18` and a `debtDrawn` of the attacker's choosing. `indexer/src/router.ts:89` records the fabricated `priceX18` as the position's entry price.
6. Repeat with the inverse on `decreasePosition` to fabricate realized PnL.

#### Recommendation

Two options; (a) is the smaller change and also removes the `ASSERT_FILL`-via-`settleFor` soft spot.

**(a) Constrain the pool for the curated entry points only**, leaving `execute` unconstrained for advanced users:

```solidity
// src/MarginRouter.sol — add governance-curated hook allowlist alongside the adapter allowlist
mapping(IHooks hooks => bool isAllowed) internal _allowedHooks;

/// @notice Reverts unless the pool's hook is the zero address or governance-allowlisted.
function _requireAllowedHook(PoolKey calldata key) internal view {
    if (address(key.hooks) != address(0) && !_allowedHooks[key.hooks]) {
        revert HookNotAllowed(address(key.hooks));
    }
}
```

Call it in `_increase` (before `src/MarginRouter.sol:443`) and in `decreasePosition` (before `src/MarginRouter.sol:220`).

**(b) Or stop treating the events as a price oracle**: remove the derived-price instruction from `src/interfaces/IMarginRouter.sol:66-67`, and have the indexer derive price from the `PoolManager` `Swap` events of pools it independently recognises rather than from `debtDrawn / collateralBought`.

---

### L-06 — Full close collides with the `OPEN_DELTA == 0` sentinel when collateral is zero and debt is not, making a post-liquidation position unclosable via the curated path

| | |
|---|---|
| **Severity** | Low (Impact: Low — liveness and diagnosability, no fund loss; Likelihood: Possible — reachable after a severe liquidation or a subId-reuse mistake) |
| **Type** | Logic / Sentinel collision |
| **Location** | [`src/MarginRouter.sol:236`](../src/MarginRouter.sol#L236) |
| **Agents** | [agents: 1/8] — `first-principles` |
| **Verdict** | **UNVERIFIED** (mechanism traced, citations re-verified; no adversarial pass) |
| **Status** | Confirmed |

#### Description

`ActionConstants.OPEN_DELTA == 0` (`src/libraries/ActionConstants.sol:10`). The full-close withdrawal amount is computed, not chosen from a sentinel-free space:

```solidity
// src/MarginRouter.sol:233-238
actionParams[4] = abi.encode(
    params.adapter,
    params.market,
    fullClose ? collateralBefore : uint256(ActionConstants.OPEN_DELTA),
    address(this)
);
```

and the handler resolves any zero to the sentinel meaning:

```solidity
// src/MarginRouter.sol:569
if (amount == ActionConstants.OPEN_DELTA) amount = _getFullDebt(market.collateral);
```

So when `fullClose == true` and `collateralBefore == 0`, the intended "withdraw nothing" silently becomes "withdraw the swap's entire collateral input" from a position that holds no collateral.

The debt-free early return does not cover this, because it requires `debt == 0`:

```solidity
// src/MarginRouter.sol:175
if (fullClose && debt == 0) {
```

`collateralBefore == 0 && debt > 0` is reachable two ways:

- **(a)** A liquidation that seized all collateral but left residual debt (an Aave v3 `liquidationCall` where collateral is insufficient to cover the bonus).
- **(b)** An Aave v3 / Aave v4 account whose debt reserve is shared across markets — the documented one-position-per-`subId` usage requirement the router explicitly does not enforce (`src/AaveLendingAdapter.sol:216-217`: "The router does NOT enforce one position per account") — being full-closed against a market whose collateral asset it holds none of. `positionOf`'s collateral read is asset-specific (`src/AaveLendingAdapter.sol:191-193`) while its debt read is reserve-level (`src/AaveLendingAdapter.sol:192-194`).

#### Impact

The curated full close reverts with an opaque lending-protocol underflow (Morpho `position.collateral -= assets`, Aave `NotEnoughAvailableUserBalance`, Comet `userCollateral.balance -= amount`) instead of a clear error, and the position cannot be wound down through `decreasePosition` at all. The user must fall back to an `execute` plan with an explicit withdraw amount, or to `MarginAccount.execute`. No funds are lost — all four venues revert rather than mis-transferring — so this is a liveness and diagnosability defect in exactly the post-liquidation state where users are already distressed.

#### Exploit path

1. An Aave v3 USDC-collateral / WETH-debt position is partially liquidated: all aUSDC seized, WETH variable debt remains.
2. Owner calls `decreasePosition({adapter: AaveLendingAdapter, market: (USDC, WETH), debtToRepay: type(uint256).max, maxCollateralIn: N, ...})`.
3. `src/MarginRouter.sol:171` returns `(collateralBefore = 0, debt = D > 0)`. The branch at `:175` is skipped because `debt != 0`.
4. `src/MarginRouter.sol:236` encodes withdraw amount `collateralBefore == 0`.
5. Inside the unlock: `SWAP_EXACT_OUT_SINGLE` buys `D` of WETH, `ASSERT_FILL` passes, `TAKE` sends it to the account, `ACCOUNT_REPAY(max)` clears the debt.
6. `ACCOUNT_WITHDRAW_COLLATERAL`: `src/MarginRouter.sol:569` sees amount `0`, resolves it to `_getFullDebt(USDC)` — the swap's USDC input — and asks Aave to withdraw that from an account with zero aUSDC.
7. Revert. Retrying produces the same result.

#### Recommendation

Reject the ambiguous state at the encode site with a named error, since the handler cannot distinguish a genuine zero from the sentinel:

```solidity
// Before (src/MarginRouter.sol:196-199)
if (params.maxCollateralIn == 0) revert SlippageBoundRequired();
_setActiveAccount(account);

// After — add `error NoCollateralToWithdraw();` to IMarginRouter
if (params.maxCollateralIn == 0) revert SlippageBoundRequired();
// a full close with debt but zero collateral cannot fund its own repay swap, and encoding a
// zero withdraw amount would alias to the OPEN_DELTA sentinel and withdraw the full swap cost
if (fullClose && collateralBefore == 0) revert NoCollateralToWithdraw();
_setActiveAccount(account);
```

The caller then repays out of pocket via an `execute` plan (`PULL_TO_ACCOUNT` + `ACCOUNT_REPAY`), after which the debt-free path at `src/MarginRouter.sol:175` succeeds. Document that fallback in `decreasePosition`'s NatSpec so integrators build it into their UX rather than discovering it on revert.

A cleaner but larger fix is to remove the overload entirely: introduce a distinct `EXACT_AMOUNT` encoding so a computed zero cannot be read as "use the full delta", and apply it at `src/MarginRouter.sol:236` and symmetrically at `:473`/`:475`.

---

### L-07 — `decreasePosition` never bounds `debtToRepay` by the debt it just read, so an over-repay silently caps on the Aave adapters and misreports `debtRepaid`

| | |
|---|---|
| **Severity** | Low (Impact: Low — caller-self-inflicted, recoverable value stranding plus event over-count; Likelihood: Possible — a caller or frontend parameter mistake) |
| **Type** | Input validation / Logic |
| **Location** | [`src/MarginRouter.sol:171`](../src/MarginRouter.sol#L171) |
| **Agents** | [agents: 2/8] — `math-precision` (FINDING), `vector-scan` (independent LEAD, same group) |
| **Verdict** | **UNVERIFIED** (mechanism traced, citations re-verified; venue capping behaviour read from vendored interface NatSpec rather than executed) |
| **Status** | Confirmed |

#### Description

`decreasePosition` reads the position's current debt at `src/MarginRouter.sol:171` but uses it only on the `fullClose` branch. For a partial decrease it feeds the caller's `params.debtToRepay` straight into the exact-output swap (`src/MarginRouter.sol:221`), the fill assertion (`src/MarginRouter.sol:230`), and the repay (`src/MarginRouter.sol:232`) with no `debtToRepay <= debt` check. The only validation is non-zero-ness and the health bound:

```solidity
// src/MarginRouter.sol:166-168
if (!fullClose && (params.debtToRepay == 0 || Ltv.unwrap(params.maxLtvAfter) == 0)) {
    revert SlippageBoundRequired();
}
```

The three venues then diverge:

- **Morpho** reverts safely: an asset-denominated repay (`src/MorphoLendingAdapter.sol:136`) subtracts converted shares from `position.borrowShares` and underflows.
- **Aave v4** silently caps: `src/interfaces/external/aave-v4/ISpoke.sol:121-123` documents "An amount greater than the total debt is capped to the total debt (drawn plus premium)". Aave v3's `IPool.repay` caps the same way (`src/interfaces/external/aave/IPool.sol:37-38`).
- **Compound** converts the excess into a positive base *supply* balance (`src/interfaces/external/compound-v3/IComet.sol:15-17`).

On the capping venues the router has already sold collateral for the full `debtToRepay`, because the swap and the `TAKE` to the account are sized off it. The collateral leg withdraws exactly `_getFullDebt` (`src/MarginRouter.sol:236` → `:569`) and `SETTLE` pays exactly that (`src/MarginRouter.sol:239`), so `residual` at `src/MarginRouter.sol:248` is zero and nothing is returned to the caller. The un-repaid surplus sits in the `MarginAccount`.

The emitted event compounds it: `src/MarginRouter.sol:275` reports `params.debtToRepay`, not the amount actually repaid — even though `MarginAccount.repay` already returns the measured `repaid` (`src/MarginAccount.sol:115`) and the spec defines the field as "The debt repaid" (`src/interfaces/IMarginRouter.sol:106-108`).

#### Impact

A partial decrease with `debtToRepay` above the outstanding debt sells more collateral than the repay consumes on the Aave v3 / Aave v4 adapters. The surplus is not lost — it sits in the caller's own `MarginAccount` and is recoverable via `MarginAccount.sweep` (`src/MarginAccount.sol:120-125`) or an `ACCOUNT_SWEEP` plan — but it is silently stranded with no event distinguishing it, and indexers over-count repayments. Behaviour is non-uniform across venues (Morpho reverts, Aave strands, Compound converts to a base supply), which is itself a maintenance hazard.

#### Exploit path

1. Hold an Aave v3 (or v4) short position with ~1.0 WETH of debt.
2. Call `decreasePosition` with `debtToRepay = 1.5e18` and a `maxCollateralIn` large enough to cover it.
3. The exact-output swap buys 1.5 WETH, `ASSERT_FILL` passes, `TAKE` sends 1.5 WETH to the account.
4. `IPool.repay(WETH, 1.5e18, 2, account)` caps at 1.0 WETH, leaving 0.5 WETH in the account.
5. `ACCOUNT_WITHDRAW_COLLATERAL(OPEN_DELTA)` + `SETTLE` pay the pool the full USDC cost of 1.5 WETH, so `residual` at `src/MarginRouter.sol:248` is zero.
6. `PositionDecreased` is emitted with `debtRepaid = 1.5e18` while only 1.0e18 was repaid.

#### Recommendation

Bound the repay by the debt already read, which also makes the three venues behave uniformly:

```solidity
// src/MarginRouter.sol — immediately after the positionOf read at L171
account = accountOf(msgSender(), params.subId);
(uint256 collateralBefore, uint256 debt) = params.adapter.positionOf(account, params.market);

// Before: nothing bounds params.debtToRepay against `debt`
// After — add `error RepayExceedsDebt(uint256 requested, uint256 outstanding);` to IMarginRouter
if (!fullClose && params.debtToRepay > debt) revert RepayExceedsDebt(params.debtToRepay, debt);
```

Independently, emit the measured repay rather than the requested amount. `MarginAccount.repay` already returns it (`src/MarginAccount.sol:115`); surface it through the `ACCOUNT_REPAY` handler (`src/MarginRouter.sol:578-580`) into the event at `src/MarginRouter.sol:275`, or drop the field from the partial-decrease emit and let indexers use the account-level `Repaid` event (`src/interfaces/IMarginAccount.sol:60`), which is already measured.

---

### L-08 — Full-close `PositionDecreased` asserts an empty position without reading it back, and leftover debt-token dust in the account is never swept

| | |
|---|---|
| **Severity** | Low (Impact: Low — index corruption plus user-visible but recoverable dust; Likelihood: Possible — requires the unenforced one-position-per-subId requirement to be violated, or a max-repay/swap mismatch) |
| **Type** | Logic / Event correctness |
| **Location** | [`src/MarginRouter.sol:254`](../src/MarginRouter.sol#L254) |
| **Agents** | [agents: 1/8] — `first-principles` |
| **Verdict** | **UNVERIFIED** (mechanism traced, citations re-verified; no adversarial pass) |
| **Status** | Confirmed |

#### Description

On the full-close path the router emits hardcoded terminal state, justified at `src/MarginRouter.sol:251-253` ("A full close ends empty by construction, so its resulting state is a known zero and needs no position read"):

```solidity
// src/MarginRouter.sol:254-267
if (fullClose) {
    emit PositionDecreased(
        msgSender(), account, params.market.collateral, params.market.debt,
        debt,               // from the PRE-unlock read at L171
        collateralBefore,   // ditto
        residual,
        0,                  // collateralTotal
        0,                  // debtTotal
        Ltv.wrap(0),        // currentLtv
        type(uint256).max   // healthFactorWad
    );
}
```

Three ways that construction does not hold:

1. **Aave v3 / Aave v4 / Comet debt reads are account-level**, documented at `src/AaveLendingAdapter.sol:38-45`, `src/AaveV4LendingAdapter.sol:46-52`, and `src/CompoundV3LendingAdapter.sol:43-47`. If the account holds a second position under the same `subId` — which the router explicitly does not enforce against (`src/AaveLendingAdapter.sol:216-217`) — the event declares the position closed while collateral and debt remain. This converts an unenforced *usage* requirement into silent *index corruption*, a distinct consequence from the read-blending already documented.
2. **`debtRepaid: debt` is the pre-unlock read**, not what the protocol consumed. `ACCOUNT_REPAY` passes `type(uint256).max` (`src/MarginRouter.sol:232`) and each venue resolves it independently — Morpho by shares (`src/MorphoLendingAdapter.sol:131-134`), Aave v4 by the Spoke's own cap (`src/AaveV4LendingAdapter.sol:194-201`). Any divergence is reported as if exact.
3. **Nothing measures or sweeps the account's residual debt-token balance.** The full close measures only the *router's* collateral delta (`src/MarginRouter.sol:244-249`). If a max repay consumes less than the swap delivered, the surplus is stranded in the account with no curated recovery path.

#### Impact

Downstream systems that treat these events as authoritative will mark positions closed that are not. The in-repo indexer does exactly that. A co-located Aave position would be reported as fully closed with zero debt while remaining liquidatable — an operational blind spot precisely where monitoring matters. Stranded debt-token dust is user-visible loss until the owner runs an `execute` plan with `ACCOUNT_SWEEP`. No third-party fund loss.

#### Exploit path

1. A user (or an integrator with a `subId`-reuse bug) opens two Aave v3 positions under one `subId`: USDC collateral with WETH debt, and WBTC collateral with WETH debt. Both markets are allowlisted.
2. The user full-closes `(USDC, WETH)`. `src/MarginRouter.sol:171` returns `collateralBefore` = the aUSDC balance (asset-specific) and `debt` = total WETH variable debt (reserve-level, i.e. **both** positions' debt).
3. The swap buys the combined debt, `ACCOUNT_REPAY(max)` clears all WETH debt, and only the aUSDC is withdrawn. The WBTC collateral is untouched.
4. `src/MarginRouter.sol:255-267` emits `collateralTotal: 0, debtTotal: 0, healthFactorWad: type(uint256).max`.
5. Reality: the account still holds WBTC collateral. Every indexer and monitoring system now believes the account is empty.

#### Recommendation

Read back on the full-close path too, using the same call the partial path already uses at `src/MarginRouter.sol:269`. The extra read is one call and a full close is not gas-critical:

```solidity
// Before (src/MarginRouter.sol:254-267) — hardcoded terminal state
if (fullClose) {
    emit PositionDecreased(
        msgSender(), account, params.market.collateral, params.market.debt,
        debt, collateralBefore, residual, 0, 0, Ltv.wrap(0), type(uint256).max
    );
}

// After — emit the ACTUAL resulting state, which is a known zero only when the usage
// requirement (one position per subId) actually held
if (fullClose) {
    PositionData memory position = params.adapter.describePosition(account, params.market);
    emit PositionDecreased(
        msgSender(),
        account,
        params.market.collateral,
        params.market.debt,
        debt,
        collateralBefore - position.collateralAmount,
        residual,
        position.collateralAmount,
        position.debtAmount,
        position.currentLtv,
        position.healthFactorWad
    );
}
```

Separately, append an `ACCOUNT_SWEEP` of `market.debt` to `msgSender()` at the end of the full-close plan (`src/MarginRouter.sol:201-209`) so the account is provably empty of the debt token, and derive `debtRepaid` from `MarginAccount.repay`'s measured return (`src/MarginAccount.sol:115`) rather than from the pre-unlock read.

Note this recommendation interacts with L-04: on a Comet whose base can round to zero USD value, adding a `describePosition` call to the full-close path would newly expose the full close to that panic. Fix L-04 first.

---

### I-01 — `Market.toSwapParams` is documented as an unbypassable pool/market reconciliation choke point, but `execute` plans never reach it

| | |
|---|---|
| **Severity** | Informational |
| **Type** | Documentation / Spec divergence |
| **Location** | [`src/libraries/MarginActions.sol:15`](../src/libraries/MarginActions.sol#L15) |
| **Agents** | [agents: 1/8] — `vector-scan` |
| **Verdict** | **UNVERIFIED** (citations re-verified) |

Two comments claim an unconditional structural guarantee. `src/libraries/MarginActions.sol:15-16`: "There is no market/swap reconciliation opcode: that check is enforced when swap params are built by `Market.toSwapParams`, so it cannot be skipped and needs no separate action." `src/types/Market.sol:46-50`: "Every margin flow builds its swap params here, so a pool/market currency mismatch is structurally unable to reach the lending legs… it cannot be bypassed."

Both hold only for the curated entry points. `toSwapParams`'s two call sites are `src/MarginRouter.sol:220` and `src/MarginRouter.sol:443`. In an `execute` plan the swap opcodes fall through `src/MarginRouter.sol:506` and `:530` into `V4Router._handleAction` (`src/V4Router.sol:34-53`), which decodes a raw caller-supplied `ExactOutputSingleParams`/`ExactInputSingleParams` containing an arbitrary `poolKey` and an arbitrary `zeroForOne`, and calls `_swap` (`src/V4Router.sol:196`) with no reference to `Market` at all.

No direct exploit — the account-scoped opcodes still validate the market through the adapter's registry, and `execute` is documented as unguarded — but an integrator reading these comments would reasonably conclude that `execute` plans are pool/market reconciled, which they are not. That is the kind of misreading that leads a plan builder to omit its own check.

**Fix:** scope both comments to the curated flows, and add a point 9 to the `execute` plan-composition contract at `src/interfaces/IMarginRouter.sol:300-328`:

```
///         9. Pool/market reconciliation: the curated entry points route every swap through
///            `Market.toSwapParams`, which asserts the pool trades exactly the market pair.
///            `execute` plans do NOT: the swap opcodes take a raw caller-supplied `poolKey`
///            and `zeroForOne`. A plan must reconcile its own pool against the market it
///            supplies or borrows against.
```

---

### I-02 — `_pay` uses an unchecked truncating `uint160(amount)` cast while every other Permit2 pull in the contract uses `SafeCast`

| | |
|---|---|
| **Severity** | Informational |
| **Type** | Math / Unsafe cast |
| **Location** | [`src/MarginRouter.sol:633`](../src/MarginRouter.sol#L633) |
| **Agents** | [agents: 1/8] — `vector-scan` |
| **Verdict** | **UNVERIFIED** (citations re-verified) |

`src/MarginRouter.sol:633` truncates without checking:

```solidity
permit2.transferFrom(payer, address(poolManager), uint160(amount), Currency.unwrap(currency));
```

The three other Permit2 pulls in the same contract all use `SafeCast`: `addCollateral` (`src/MarginRouter.sol:308`), `_increase` (`:437`), and `PULL_TO_ACCOUNT` (`:599`) — the last with an explicit comment at `:597-598` that the checked cast is precisely what stops `CONTRACT_BALANCE` (`1 << 255`) being smuggled onto the caller. `using SafeCast for uint256` is already declared at `src/MarginRouter.sol:61`.

`amount` reaching `_pay` comes from `_mapSettleAmount` (`src/base/DeltaResolver.sol:79-87`), which passes an unvalidated caller-supplied literal through on the `else` branch at `:85`, so an `execute` plan can supply any `uint256` to a `SETTLE` with `payerIsUser = true`.

No fund loss: truncation can only under-pay, and `poolManager.settle()` credits by the measured balance delta, so the router's negative delta stays non-zero and the PoolManager reverts `CurrencyNotSettled` at the end of the unlock. The effect is an opaque revert instead of a clear cast failure, plus an inconsistency that invites the pattern to be copied into a context where truncation is not self-correcting.

```solidity
// Before (src/MarginRouter.sol:633)
permit2.transferFrom(payer, address(poolManager), uint160(amount), Currency.unwrap(currency));

// After — matches L308, L437, L599
permit2.transferFrom(payer, address(poolManager), amount.toUint160(), Currency.unwrap(currency));
```

---

### I-03 — `IComet` NatSpec contradicts the Compound v3 full-repay correctness argument the adapter depends on

| | |
|---|---|
| **Severity** | Informational |
| **Type** | Documentation / Integration |
| **Location** | [`src/interfaces/external/compound-v3/IComet.sol:18`](../src/interfaces/external/compound-v3/IComet.sol#L18) |
| **Agents** | [agents: 1/8] — `periphery` |
| **Verdict** | **UNVERIFIED** (citations re-verified) |

`src/interfaces/external/compound-v3/IComet.sol:18-19` states: "`borrowBalanceOf` is denominated in the base token and reflects interest accrued as of the last protocol interaction (**it is not re-accrued to `block.timestamp` in the view**)", repeated at `:74-76`.

`CompoundV3LendingAdapter.encodeRepay` relies on the exact opposite. `src/CompoundV3LendingAdapter.sol:167-171`: "reads `borrowBalanceOf(account)` and supplies exactly that: the balance is accrued to `block.timestamp`, so in the repay's own block it equals the amount owed and the borrow clears to zero with no dust (verified on a mainnet fork)", and `:44` calls it "the account's base borrow accrued to `block.timestamp`".

The adapter is the correct one. The read at `src/CompoundV3LendingAdapter.sol:178` and the write are unconditionally in the same transaction — encoded at `src/MarginAccount.sol:109`, executed at `:113`, with only two balance reads in between — so there is no read/write accrual skew window at all. `test/fork/CompoundV3LendingAdapter.fork.t.sol:163` pins it on a mainnet fork with `assertEq(debtEnd, 0, "close: borrow fully repaid on Comet (no dust)")`.

No runtime impact. The risk is review and maintenance: the vendored interface is the pinned reference for Comet's semantics, and it asserts a property that would imply the full-repay path leaves permanent dust. A maintainer trusting `IComet.sol:18-19` could "fix" `encodeRepay` by adding a buffer, introducing either real dust or an over-supply that silently converts the user's excess base into an invisible Comet base-supply position that `positionOf` reports as zero debt.

**Fix:** correct the interface doc to match the deployed Comet — `borrowBalanceOf` simulates accrual to `block.timestamp` before returning the present value, which is exactly what makes the exact-balance full repay dust-free — and record *why* the pairing is safe (the adapter's read and the account's `supply` are always in the same transaction, hence the same accrual timestamp) where a future editor will see it.

---

### I-04 — `createAccount` is public and permissionless with an arbitrary `owner`, letting anyone emit `AccountCreated` for addresses that never opted in

| | |
|---|---|
| **Severity** | Informational |
| **Type** | Griefing / Indexer integrity |
| **Location** | [`src/MarginAccountFactory.sol:58`](../src/MarginAccountFactory.sol#L58) |
| **Agents** | [agents: 2/8] — `vector-scan`, `access-control` (the latter classified it as correctly mitigated for funds, which it is) |
| **Verdict** | **UNVERIFIED** (citations re-verified) |

`MarginAccountFactory.createAccount(address owner, uint256 subId)` is `public virtual` (`src/MarginAccountFactory.sol:58`) and `MarginRouter` overrides only `accountOf` (`src/MarginRouter.sol:339-346`), so the live router exposes `createAccount(address,uint256)` to anyone with a caller-chosen `owner`.

Funds-wise this is inert and the design anticipates it: the salt binds `owner` (`src/MarginAccountFactory.sol:81`) and the immutable args bake `(owner, manager)` into the bytecode (`:70-72`), so squatting a predicted address merely deploys the victim's own account — the comment at `:74-76` says exactly that — and `MarginAccount` has no initializer to front-run. `createAccount` is also idempotent via the `code.length == 0` guard at `:60`.

The residue is the event. `src/MarginAccountFactory.sol:63` emits `AccountCreated(owner, account, subId)`, and `src/interfaces/IMarginRouter.sol:63-66` documents that indexers pair `AccountCreated` with `PositionIncreased`. An attacker can spray `AccountCreated` for arbitrary owners and arbitrary `subId`s at clone-deploy cost, so an indexer keyed on that event shows phantom sub-accounts for users who never interacted.

**Fix:** if account deployment is meant to be reachable only through the flows, narrow the router's surface:

```solidity
// src/MarginRouter.sol — add alongside the accountOf override at L339-346
/// @dev Account deployment is an implementation detail of the position flows; expose only the
///      view. Overriding to internal keeps the factory's lazy-deploy behavior without an
///      unauthenticated public entry point that emits AccountCreated for arbitrary owners.
function createAccount(address owner, uint256 subId) internal override returns (address account) {
    return super.createAccount(owner, subId);
}
```

(Requires widening the base's visibility to `internal virtual` and adjusting `MarginAccountFactory` accordingly — the router's four internal call sites at `src/MarginRouter.sol:295`, `:423`, `:540` are unaffected.) If permissionless lazy deployment is intentional, say so in the `AccountCreated` NatSpec at `src/MarginAccountFactory.sol:27-31` so indexers know the event is not authenticated and must be corroborated by a `Position*` event.

---

### I-05 — `healthFactorWad` is not the documented `maxLtv / currentLtv` identity on the Aave adapters, and Aave v3 returns two different `maxLtv` values for one market

| | |
|---|---|
| **Severity** | Informational |
| **Type** | Logic / Cross-adapter semantic inconsistency |
| **Location** | [`src/types/PositionData.sol:18`](../src/types/PositionData.sol#L18) |
| **Agents** | [agents: 1/8] — `math-precision` |
| **Verdict** | **UNVERIFIED** (citations re-verified) |

`PositionData` specifies `healthFactorWad` as "The position health factor (WAD, 1e18 == 1.0; below 1e18 is liquidatable), i.e. `maxLtv / currentLtv`" (`src/types/PositionData.sol:18-19`), and `src/interfaces/ILendingAdapter.sol:120` repeats it.

Morpho and Compound honour the identity exactly: `Math.mulDiv(collateralValue, marketParams.lltv, debt)` (`src/MorphoLendingAdapter.sol:191`) and `Math.mulDiv(collateralValue, info.liquidateCollateralFactor, debtValue)` (`src/CompoundV3LendingAdapter.sol:238`).

Aave v3 passes through the Pool's own health factor (`src/AaveLendingAdapter.sol:252`), which happens to coincide because Aave computes `collateral * avgLiquidationThreshold / debt` and the adapter pairs it with the same account-weighted threshold (`src/AaveLendingAdapter.sol:248`).

Aave v4 does not. It passes through `accountData.healthFactor` (`src/AaveV4LendingAdapter.sol:270`) while pairing it with the reserve's `collateralFactor` as `maxLtv` (`src/AaveV4LendingAdapter.sol:268`). The Spoke's health factor also incorporates the position's risk premium and dynamic config, as the adapter's own notes state (`src/AaveV4LendingAdapter.sol:42-45`), so on Aave v4 `healthFactorWad != maxLtv / currentLtv`.

Separately, the Aave v3 adapter returns two different values for the same conceptual field: `maxLtvWad(market)` reads the *reserve's* liquidation threshold (`src/AaveLendingAdapter.sol:203-205`) while `describePosition().maxLtv` reads the *account-weighted* `currentLiquidationThreshold` (`src/AaveLendingAdapter.sol:241`, `:248`). These diverge for any multi-collateral account.

All four LTV scales were verified as WAD, so this is a semantics issue, not a scale bug. No onchain control depends on either field — the only onchain check, `ASSERT_HEALTH`, compares `currentLtvWad` against a caller-supplied bound (`src/MarginRouter.sol:587`) — but the values are emitted in `PositionIncreased` / `PositionDecreased` / `CollateralAdded` (`src/MarginRouter.sol:140-142`, `:279-281`, `:320-322`), so indexers inherit the inconsistency, and a frontend deriving a liquidation price as `currentLtv * healthFactor` gets the wrong distance-to-liquidation on Aave v4.

**Fix:** either tighten the interface doc so `healthFactorWad` is defined as "the venue's authoritative health factor in WAD, which equals `maxLtv / currentLtv` only for a single-collateral, no-risk-premium position", and note that Aave v3's `describePosition().maxLtv` is account-weighted while `maxLtvWad()` is reserve-level; or make the field uniform across all four adapters and expose the venue's native value as a separate field. Using `accountData.avgCollateralFactor` (declared WAD at `src/interfaces/external/aave-v4/ISpoke.sol:68`) for Aave v4's `maxLtv` would at least make the v4 pair internally coherent.

---

### I-06 — The `0` amount sentinel means four different things across the margin opcodes; `ACCOUNT_SUPPLY_COLLATERAL(0)` silently supplies the account's entire balance

| | |
|---|---|
| **Severity** | Informational |
| **Type** | Logic / API footgun |
| **Location** | [`src/MarginRouter.sol:561`](../src/MarginRouter.sol#L561) |
| **Agents** | [agents: 1/8] — `execution-trace` |
| **Verdict** | **UNVERIFIED** (citations re-verified) |

Within one action interpreter, an encoded amount of `0` (`== ActionConstants.OPEN_DELTA`, `src/libraries/ActionConstants.sol:10`) resolves four different ways:

| Opcode | Meaning of `0` | Line |
|---|---|---|
| `ACCOUNT_SUPPLY_COLLATERAL` | the account's **token balance** | `src/MarginRouter.sol:561` |
| `ACCOUNT_WITHDRAW_COLLATERAL` | the router's negative **pool delta** | `src/MarginRouter.sol:569` |
| `ACCOUNT_BORROW` | the router's negative **pool delta** | `src/MarginRouter.sol:576` |
| `ACCOUNT_SWEEP`, `ACCOUNT_REPAY` | literally zero — moves nothing | `src/MarginRouter.sol:582-583`, `:579-580` |
| `PULL_TO_ACCOUNT` | **rejected** | `src/MarginRouter.sol:595` |

The `ACCOUNT_SUPPLY_COLLATERAL` case is the only `OPEN_DELTA` in the file that means "balance"; everywhere else in v4-periphery, "entire balance" is spelled `CONTRACT_BALANCE` (`src/libraries/ActionConstants.sol:13`).

The codebase already identifies this exact hazard class and defends against it on one opcode while leaving the most dangerous instance undefended — `src/MarginRouter.sol:592-595`: "a pull with no amount is always a plan-builder error, so reject it loudly rather than silently moving nothing (which would compose badly with opt-in health checks)."

A related asymmetry: the `to` field of `ACCOUNT_WITHDRAW_COLLATERAL` and `ACCOUNT_BORROW` is **not** passed through `_mapRecipient` (`src/MarginRouter.sol:570`, `:577`), unlike `SWEEP` (`:514`) and `TAKE` (`src/V4Router.sol:73`), so the `MSG_SENDER`/`ADDRESS_THIS` sentinels silently fail `_requireReceiver` (`src/MarginAccount.sol:163-165`) on those two opcodes.

Impact is confined to `execute` plan-builder error, inside the caller's own account, which the interface already declares equivalent to handing over the sub-account (`src/interfaces/IMarginRouter.sol:321-325`). Raised because it directly undercuts the stated rationale at `src/MarginRouter.sol:592-595`.

**Fix:** make the sentinel uniform and explicit.

```solidity
// Before (src/MarginRouter.sol:557-562)
if (action == MarginActions.ACCOUNT_SUPPLY_COLLATERAL) {
    (ILendingAdapter adapter, Market memory market, uint256 amount) = params.decodeAdapterMarketAmount();
    _requireAllowedAdapter(adapter);
    if (amount == ActionConstants.OPEN_DELTA) amount = market.collateral.balanceOf(account);
    IMarginAccount(account).supplyCollateral(adapter, market, amount);
}

// After — a computed zero can no longer mean "supply everything"
if (action == MarginActions.ACCOUNT_SUPPLY_COLLATERAL) {
    (ILendingAdapter adapter, Market memory market, uint256 amount) = params.decodeAdapterMarketAmount();
    _requireAllowedAdapter(adapter);
    // 0 is a plan-builder error here, matching PULL_TO_ACCOUNT; use CONTRACT_BALANCE to mean
    // "the account's whole balance", consistent with the rest of v4-periphery
    if (amount == 0) revert SlippageBoundRequired();
    if (amount == ActionConstants.CONTRACT_BALANCE) amount = market.collateral.balanceOf(account);
    IMarginAccount(account).supplyCollateral(adapter, market, amount);
}
```

This requires updating `_increase`'s `actionParams[3]` from `uint256(ActionConstants.OPEN_DELTA)` to `ActionConstants.CONTRACT_BALANCE` at `src/MarginRouter.sol:473`. If the encoding must stay as-is, document the per-opcode meaning of `0` in the `execute` contract at `src/interfaces/IMarginRouter.sol:300-328` alongside the existing point 6, and note that `to` is unmapped on the withdraw and borrow opcodes.

---

### I-07 — `maxLtvAfter`'s protection is only as strong as each lending venue's own oracle resistance to same-block manipulation

| | |
|---|---|
| **Severity** | Informational (cross-reference; no code fix proposed) |
| **Type** | MEV / Oracle interaction |
| **Location** | [`src/MarginRouter.sol:587`](../src/MarginRouter.sol#L587) |
| **Agents** | [agents: 1/8] — `economic` |
| **Verdict** | **UNVERIFIED — out of the reporting agent's scope, deliberately not traced** |

`ASSERT_HEALTH`'s protection (`src/MarginRouter.sol:584-589`) is only as good as `adapter.currentLtvWad`, which reads each venue's own oracle: Morpho's per-market `IOracle` (`src/MorphoLendingAdapter.sol:211`), Aave v3's price oracle via `getUserAccountData` (`src/AaveLendingAdapter.sol:222`), Aave v4's Spoke data (`src/AaveV4LendingAdapter.sol:244`), Comet's price feeds (`src/CompoundV3LendingAdapter.sol:228-229`).

Because these are the same oracles the venues use for liquidation, a v4-pool-spot flash loan cannot make an unhealthy position read healthy — that is the correct design and is recorded as mitigated in Appendix D. The open question is narrower: if any *specific* allowlisted market's oracle were itself atomically manipulable within the same block as the sandwiched open (e.g. a short-TWAP oracle sourced from a thin or correlated pool), an attacker could move both the v4 pool price and the venue oracle together, defeating `maxLtvAfter` as well.

This was explicitly out of the reporting agent's scope and was not verified against any live market's oracle configuration. Recorded so the question is not silently dropped.

**Action:** an oracle-focused review should confirm, per live market, that none is attacker-manipulable within one transaction alongside the v4 pool used for sizing — the Morpho oracle for the WETH/USDC market, the Aave v3 and Aave v4 price oracles for USDC/WETH, and the Comet price feeds for UNI/USDC.

---

## 3. Open leads (confidence < 75, not verified)

These are recorded for completeness with the specific verification each one needs. They are **not** findings: each has an untraced step, and most turn on external protocol internals that are out of scope for this review and were read from vendored interface NatSpec rather than protocol source.

| ID | Lead | Location | Agents | Confidence | What would settle it |
|----|------|----------|--------|-----------|----------------------|
| LD-01 | Aave v4 is the only venue whose withdrawal routes *through* the `MarginAccount` (`ISpoke.withdraw` pays `msg.sender`, `src/interfaces/external/aave-v4/ISpoke.sol:96-106`; encoded at `src/AaveV4LendingAdapter.sol:173` discarding the `receiver` at `:166`), so a blocklisted account clone may lose its USDC collateral with no escape — `MarginAccount.execute` (`src/MarginAccount.sol:135-136`) forwards to the Spoke, which still pays the blocklisted `msg.sender`. The other three adapters pass a receiver into the protocol call (`src/MorphoLendingAdapter.sol:103`, `src/AaveLendingAdapter.sol:142`, `src/CompoundV3LendingAdapter.sol:147`) so the account is never a transfer party. | [`src/AaveV4LendingAdapter.sol:166`](../src/AaveV4LendingAdapter.sol#L166) | `periphery` | 62 | The exact revert site inside the live Spoke (SafeERC20 vs raw transfer; Hub vs Spoke performing the outbound transfer), and whether Aave v4 exposes any recipient-bearing exit or a supply-share transfer that sidesteps the account. |
| LD-02 | `increasePosition` has no router-balance conservation guard. `decreasePosition` gets one for free via the checked subtraction at `src/MarginRouter.sol:248`; `_increase` has no analogue. `MarginAccount.borrow` forwards the *measured* delta (`src/MarginAccount.sol:98-99`), so a venue that delivers less than requested would make `SETTLE` (`src/MarginRouter.sol:477`) draw the difference from the router's own balance via `_pay` (`:631`), or revert opaquely. | [`src/MarginRouter.sol:475`](../src/MarginRouter.sol#L475) | `vector-scan`, `execution-trace` | 55 | Whether any live venue under-delivers. Morpho, Aave v3, and Comet deliver exactly `amount`; Aave v4's `borrow` returns `(drawnShares, drawnAmount)` (`src/interfaces/external/aave-v4/ISpoke.sol:115-117`) and 1-wei share rounding is plausible but unverified. Fork-test an Aave v4 `increasePosition` and assert `market.debt.balanceOfSelf()` is unchanged across the unlock. |
| LD-03 | A residual bad-debt position (`collateral == 0, debt > 0`) after an Aave v3/v4 liquidation makes the full-close swap path revert, because the withdraw at `src/MarginRouter.sol:236` supplies too little collateral for the `SETTLE` at `:239`. Morpho self-heals (its `liquidate` socializes bad debt, so the position lands in the `debt == 0` branch at `:175`); Aave may not. Overlaps L-06, which fixes the diagnosability half. | [`src/MarginRouter.sol:175`](../src/MarginRouter.sol#L175) | `economic` | 55 | Whether Aave v3/v4 `liquidationCall` can actually leave `collateral == 0` with `debt > 0` — Aave internals are out of scope and were not read. |
| LD-04 | `msg.value` is re-observed by every `multicall` leg (`delegatecall` at `src/base/Multicall_v4.sol:13` preserves it), and both native-funded entry points credit a full `msg.value` of WETH per leg (`src/MarginRouter.sol:298-303`, `:431-434`). Containment is incidental rather than checked: `_wrap` is a real `WETH9.deposit{value:}` (`src/base/NativeWrapper.sol:23`) that reverts once the router's actual ETH balance is exhausted. | [`src/base/Multicall_v4.sol:13`](../src/base/Multicall_v4.sol#L13) | `execution-trace` | 55 | Nothing onchain — the lead is that containment is an accident of `WETH9.deposit` reverting, not a guard, so it becomes a real double-spend the moment the router is expected to hold ETH by design. Today the only reachable variant claims a router ETH residual, already accepted at `src/interfaces/IMarginRouter.sol:311-313`. Worth pre-emptively adding an `address(this).balance` check before wrapping. |
| LD-05 | `AaveLendingAdapter` caches the Aave v3 protocol data provider immutably with no setter (`src/AaveLendingAdapter.sol:96-102`), justified at `:27-28` as "upgradeable proxies whose addresses are stable across Aave upgrades". That holds for the Pool but Aave's `AaveProtocolDataProvider` is a plain non-proxy contract that governance has repointed before. A repoint plus a `ReserveData` layout change would make `positionOf` (`:191-192`) mis-decode, denying the whole curated path with no in-contract remediation. | [`src/AaveLendingAdapter.sol:96`](../src/AaveLendingAdapter.sol#L96) | `periphery` | 55 | Whether the current mainnet data provider will be repointed again and whether the next Pool upgrade changes the decoded layout — both outside this repo, and no RPC was available. Cheap hardening regardless: resolve the data provider per call from the immutable addresses provider, or add an owner-gated `refreshDataProvider()`. Also correct the note at `:27-28`, which asserts the data provider is a proxy. |
| LD-06 | Partial `decreasePosition` on Aave v4 may revert on share rounding: the withdraw is asked for exactly `_getFullDebt(collateral)` (`src/MarginRouter.sol:236` → `:569`) and `SETTLE` demands the same (`:239`), but Aave v4 delivers to the account and `MarginAccount.withdrawCollateral` forwards its *measured* delta (`src/MarginAccount.sol:78-79`). A 1-wei shortfall reverts in `_pay` (empty router) or underflows at `src/MarginRouter.sol:248` (non-empty router). | [`src/MarginRouter.sol:236`](../src/MarginRouter.sol#L236) | `vector-scan` | 45 | Aave v4's rounding direction, read from vendored `ISpoke` docs rather than source. Fork-test a partial decrease against the deployed Spoke at a block where the collateral reserve's share index is not a whole multiple, instrument `withdrawCollateral`, and assert `withdrawn == amount`. |

---

## Appendix A — Scope

Commit `e3d86dd2f8199e4265adf0579ba3af953aeb2a0b`. 19 files, 1,326 nSLOC.

### A.1 Files in scope

| File | nSLOC | Description |
|------|------:|-------------|
| `src/MarginRouter.sol` | 410 | Entry point, v4 action interpreter, governance, adapter allowlist |
| `src/MarginAccount.sol` | 105 | Per-position soulbound clone; executes adapter-encoded lending calls |
| `src/MarginAccountFactory.sol` | 32 | CREATE2 clone-with-immutable-args factory (inherited by the router) |
| `src/MorphoLendingAdapter.sol` | 134 | Morpho Blue adapter; `MarketRegistry` routing table |
| `src/AaveLendingAdapter.sol` | 138 | Aave v3 Pool adapter; boolean pair allowlist |
| `src/AaveV4LendingAdapter.sol` | 155 | Aave v4 Spoke adapter; reserve-id route registry |
| `src/CompoundV3LendingAdapter.sol` | 148 | Compound v3 Comet adapter; single-base constraint |
| `src/base/OwnableAdapter.sol` | 24 | Shared two-step ownable base for the adapters |
| `src/types/Market.sol` | 29 | `(collateral, debt)` pair + `toSwapParams` reconciliation |
| `src/types/MarketRegistry.sol` | 23 | Morpho routing table struct + free functions |
| `src/types/Owner.sol` | 33 | Two-step ownership struct + free functions |
| `src/types/Ltv.sol` | 15 | WAD LTV user-defined value type |
| `src/types/LeverageX18.sol` | 15 | X18 leverage user-defined value type |
| `src/types/PositionData.sol` | 9 | Consolidated position snapshot struct |
| `src/libraries/MarginActions.sol` | 12 | Opcode constants `0x30`–`0x38` |
| `src/libraries/MarginCalldataDecoder.sol` | 44 | `abi.decode` helpers for the margin opcodes |
| `src/interfaces/IMarginRouter.sol` | 87 | Primary behavioral spec (events, params, `execute` contract) |
| `src/interfaces/IMarginAccount.sol` | 32 | Account primitives and events |
| `src/interfaces/ILendingAdapter.sol` | 31 | Encoder + reader surface |
| **Total** | **1,326** | |

### A.2 Reviewed as dependencies (in scope only where margin behavior depends on them)

`src/V4Router.sol`, `src/base/BaseActionsRouter.sol`, `src/base/DeltaResolver.sol`, `src/base/ReentrancyLock.sol`, `src/base/Permit2Forwarder.sol`, `src/base/Multicall_v4.sol`, `src/base/NativeWrapper.sol`, `src/base/SafeCallback.sol`, `src/base/ImmutableState.sol`, `src/libraries/Actions.sol`, `src/libraries/ActionConstants.sol`, `src/libraries/Locker.sol`.

Vendored external interfaces read for ABI and semantics agreement: `src/interfaces/external/aave/IPool.sol`, `src/interfaces/external/aave/IPoolDataProvider.sol`, `src/interfaces/external/aave/IPoolAddressesProvider.sol`, `src/interfaces/external/aave-v4/ISpoke.sol`, `src/interfaces/external/compound-v3/IComet.sol`, `lib/morpho-blue/src/interfaces/IMorpho.sol`.

### A.3 Out of scope

- Uniswap v4-core (`PoolManager`) — audited separately. Flash-accounting settlement is treated as enforced at that layer.
- Permit2, OpenZeppelin v5, Solady `LibClone`, Morpho Blue libraries.
- **Aave v3 / Aave v4 / Compound v3 protocol internals.** No Aave or Compound source is vendored in `lib/` (only `forge-std`, `morpho-blue`, `permit2`, `solady`, `v4-core`), so every claim about their internal rounding, capping, and liquidation behavior in this report derives from the vendored interface NatSpec plus same-block accrual reasoning, not from source read in this repo. This is the single largest evidence gap and it caps confidence on LD-01, LD-02, LD-03, LD-06, and I-03.
- Everything else in `src/`: `PositionManager`, `PositionDescriptor`, `hooks/`, `lens/`, `V4Quoter`, `UniswapV4DeployerCompetition`.
- `test/`, `script/`, `indexer/` — read as *evidence about* in-scope code (test coverage gaps, the indexer's consumption of events), never audited as targets.

### A.4 Accepted design decisions (not re-reported)

The following were supplied as pre-accepted and were **not** filed as novel findings. Where an agent's report collapsed into one of these, that is recorded in Appendix C.

1. `MarginRouter.execute` is an intentionally unguarded action interpreter (no slippage, health, or fill bounds; plans must self-net with `SWEEP`). Documented at `src/interfaces/IMarginRouter.sol:300-328`.
2. `MarginAccount.execute` is an owner-only escape hatch forwarding arbitrary calldata to `adapter.lendingProtocol()`; the owner may pass any adapter (`src/MarginAccount.sol:128-138`).
3. Aave v3 / Aave v4 / Compound v3 adapter reads are account-level, not per-pair. One-position-per-`subId` is a documented usage requirement the router does not enforce.
4. Adapters curate standard ERC-20 markets only; fee-on-transfer and rebasing tokens are excluded by curation.
5. The adapter allowlist is asymmetric on purpose: supply and borrow are gated; withdraw, repay, and account-sweep are not.
6. Governance and adapter-owner are trusted roles. "Governance is malicious" alone is not a finding; unexpected blast radius or irreversibility is.
7. `minHopPriceX36` is a redundant secondary bound for single-hop swaps.

---

## Appendix B — Methodology and the eight agent lenses

### B.1 Process

1. **Context packaging.** A shared package fixed the scope, the architecture, the seven accepted design decisions, the live deployment state, and the test-suite shape, so no agent spent effort re-deriving them or re-reporting them.
2. **Eight parallel agents**, each with a distinct lens (B.2) and each required to ground every claim in a line it had read, to output a `mitigated` list with the specific mitigating line whenever it concluded a pattern was handled, and to downgrade any un-traced pattern match to a LEAD.
3. **Grouping and dedupe** by mechanism (`group_key`), not by title — this collapsed three independent reports of the missing `target` validation into L-03 and two of the `debtToRepay` bound into L-07.
4. **Adversarial refutation.** Every candidate at Medium or above was handed to a refuter whose job was to break it: locate a mitigating line the reporter missed, or show the exploit chain fails at a specific step. Six candidates went in; one survived (with severity corrected from High to Low), five were refuted. Appendix C records each refutation in full, because "we checked this and here is exactly why it does not hold" is durable review output.
5. **Independent citation re-verification.** Every `src/File.sol:Lnn` reference in this report was re-read from source during report assembly. Drift found and corrected is listed in B.3.

### B.2 The eight lenses

| Agent | Lens | Coverage reached |
|-------|------|------------------|
| `vector-scan` | Per-vector sweep of every external/public function, classified Vulnerable / Suspicious / Mitigated / N/A | Full read of all 19 in-scope files plus the inherited base layer and `src/PositionManager.sol:225-286`/`:493-502` for the SWEEP/WRAP/UNWRAP semantic diff. Empirically tested the Aave v3 zero-LTV donation grief with live `cast call` reads and a mainnet fork test. |
| `math-precision` | Every arithmetic expression: scale, rounding direction, phantom overflow, sentinel collision, narrowing cast | Enumerated every arithmetic expression in scope by grep and traced each. Verified OZ `Math.mulDiv` zero-denominator behavior against the vendored copy. Reproduced L-04 with a throwaway Foundry test. |
| `access-control` | Every privileged entry point, role handoff, receiver constraint, and account-derivation path | Traced all six `MarginAccount` external functions, all four adapters' `setMarket` guards, both two-step ownership surfaces, and the six questions posed in its brief to line-level conclusions. Found no gap beyond the accepted boundaries — hence zero findings and seven mitigated entries. |
| `economic` | Sandwich, MEV, liquidation interaction, interest-accrual skew, residual-as-shared-pot | Full read of the router, account, all four adapters, `ReentrancyLock`, `Multicall_v4`. Did not read `test/`, so could not confirm whether its scenarios are already covered by assertions. |
| `execution-trace` | Entry-to-exit traces of all four entry points and all nine margin opcodes; transient-storage lifecycle; discarded return values | Produced full traces for `increasePosition`, all three `decreasePosition` branches, `addCollateral`, and `execute`. Verified `MarginAccount` has zero storage slots via `forge inspect`. Proved no `try`/`catch` exists around any unlock, making stale-transient-account leakage moot. |
| `invariants` | Seven named protocol invariants (router-residual, account-ownership, active-account, fund-custody, health, exitability, settlement), each with a status and an existing-coverage assessment | Full read of the in-scope files plus `test/invariant/` in full. Produced the only surviving finding (L-01) by asking which invariant the *code's own comments* claim, then checking whether a second gate exists that the comment does not scope. |
| `periphery` | Every encoded external call checked field-by-field against the vendored interface; clone machinery; `abi.encode`/`decode` shape agreement across all nine opcodes | Cross-checked every lending call against its interface signature, Morpho against `lib/morpho-blue`, the clone machinery against `lib/solady` v0.1.26, and the whole `Actions` opcode space for collisions. Could not execute fork tests (no RPC), so relied on pinned fork-test assertions as evidence. |
| `first-principles` | Ignore the documented threat model; ask what the code actually permits. Full opcode-space enumeration; hook-mediated manipulation from the router's side | Full read of all in-scope files plus `test/mocks/MockLendingAdapter.sol` and `indexer/src/router.ts`. Enumerated the entire `0x00`–`0xff` opcode space against the dispatcher. Produced four of the eight Low findings. |

### B.3 Citation drift found and corrected during re-verification

Every citation in this report was re-read from source. Six instances of drift were found in the agents' submitted line numbers; all were off-by-a-few pointers to the correct construct, so the findings stand with corrected references. **No finding was dropped for an unverifiable citation.**

| Reported | Correct | Note |
|----------|---------|------|
| `indexer/src/router.ts:88` | `indexer/src/router.ts:89` | The `priceX18` computation is on L89; L88 is the `consumeSwaps` call. Corrected in L-05. |
| `src/interfaces/ILendingAdapter.sol:64` (target for `encodeBorrow`) | `src/interfaces/ILendingAdapter.sol:66` | L64 is the `market` param doc. Corrected in L-03. |
| `src/CompoundV3LendingAdapter.sol:300-306` (`_requireSupportedMarket`) | `:302-306` | L300-301 are the NatSpec. Corrected in L-01. |
| `src/MarginRouter.sol:566-568` ("Not allowlist-gated") | `:567-568` | The quoted sentence spans 567-568. Corrected in L-01. |
| `src/MarginRouter.sol:592-595` cited as the rationale comment | `:592-594` comment, `:595` the revert | Both cited explicitly in I-06. |
| `src/interfaces/external/compound-v3/IComet.sol:20-21` described as recording that "Comet's constructor rejects any price feed whose `decimals() != 8`" | The file records only that `getPrice` returns a 1e8-scaled price | The stronger claim about a constructor check is **not** in the vendored interface and is not asserted anywhere in this report. Softened in Appendix D. |

One further correction of substance, not citation: the `math-precision` agent's mitigated entry for Compound price-scale cancellation rested on the constructor claim above. Since the vendored interface does not record it and Comet source is out of scope, that mitigation is downgraded in Appendix D from "invariant recorded in the interface" to "holds for the live cUSDCv3 deployment; unverified for an arbitrary Comet, and the adapter never re-checks feed decimals for the Comet it binds at `src/CompoundV3LendingAdapter.sol:100-105`." This is the same root cause as L-04 and the recommended construction-time check there addresses both.

---

## Appendix C — Refuted findings

Four candidates were filed at High or Medium and did not survive adversarial refutation. In every case the reported *code observations were accurate* — no agent misquoted a line — and the refutation turned on a mitigating line or a reachability constraint the reporter had not traced. These are recorded in full because the reasoning is the durable artifact: it documents what was examined and why the codebase is safe there.

### R-01 — [REFUTED, was High] `increasePosition` never requires a non-zero `maxLtvAfter`, so the documented sandwich-to-liquidation mitigation is opt-in

**Claim (agent: `economic`).** `_increase` validates only `collateralToBuy != 0` and `maxDebtIn != 0` (`src/MarginRouter.sol:419-420`); `maxLtvAfter` is passed through to `ASSERT_HEALTH` (`:480`) which no-ops on a zero bound (`:587`). `decreasePosition` makes the equivalent bound *mandatory* for its partial path (`:166`). So the router ships the mitigation its own docs describe (`src/interfaces/IMarginRouter.sol:175-180`) but does not enforce it on the leverage-increasing side, enabling a sandwich that consumes the full `maxDebtIn` budget and lands the position at or through the venue's liquidation LTV, followed by an immediate third-party liquidation for the bonus — a double dip.

**Refutation.** All quotes verified accurate. The exploit chain fails on three independent grounds.

1. **The mandatory bound already bounds the resulting LTV deterministically.** `maxDebtIn` is required non-zero (`src/MarginRouter.sol:420`) and is passed as `amountInMaximum` (`:460`), which `V4Router` hard-enforces: `if (amountIn > params.amountInMaximum) revert V4TooMuchRequested(...)` (`src/V4Router.sol:144`). The debt actually drawn is *exactly* the swap input, not an independent number — `ACCOUNT_BORROW` is encoded with `OPEN_DELTA` (`src/MarginRouter.sol:475`), resolved as `_getFullDebt(market.debt)` (`:576` → `src/base/DeltaResolver.sol:60-66`), i.e. precisely the negative pool delta the swap created. Collateral added is `equity` (or `msg.value`) plus `collateralToBuy`, both exact caller inputs (`src/MarginRouter.sol:431-439`, `:459`), and `ASSERT_FILL` proves the full `collateralToBuy` arrived (`:469`, `:543-549`). So worst-case post-increase debt is `debtBefore + maxDebtIn` against a fixed collateral quantity: the worst-case oracle LTV is fully computable offchain from parameters the caller must supply. `maxLtvAfter` is a convenience re-expression of the same bound in oracle units, exactly as `src/interfaces/IMarginRouter.sol:179-180` states. The claim's own premise is self-defeating: it posits `maxDebtIn` "set close to the fair-price quote", which mathematically caps the LTV drift at the caller's own slippage tolerance.
2. **"Opened at or through the liquidation LTV" is prevented by the venue, not by `ASSERT_HEALTH`.** Every borrow is a real venue call whose revert bubbles (`src/MarginAccount.sol:96-97`, `:182-183`), and all four venues enforce borrow-time collateralization. On two of the three venue types the *borrow* limit is strictly tighter than the liquidation limit `maxLtvWad` reports: `src/AaveLendingAdapter.sol:198-200` documents "Uses the liquidation threshold, not the `ltv` (max-borrow) field" (Aave validates borrows against the smaller `ltv`), and `src/CompoundV3LendingAdapter.sol:39-42` and `:197-198` state Comet gates borrows on `borrowCollateralFactor` while `maxLtvWad` returns `liquidateCollateralFactor`. Morpho is the boundary-equal case (single `lltv`) and its health check admits equality, so the worst attainable state is "at `lltv`, still healthy", not "past liquidation". The claimed immediate-liquidation step therefore has no reachable precondition on Aave v3/v4 or Comet.
3. What remains is ordinary exact-output sandwich exposure bounded by a mandatory caller-chosen cap, harming only the caller who chose the loose cap. The asymmetry with `decreasePosition:166` is defense-in-depth, and the optionality is explicitly documented behavior.

**Verdict: REFUTED.** Corrected severity Informational; not filed, because the behavior is documented at `src/interfaces/IMarginRouter.sol:179-180`.

**Decisive line:** `src/V4Router.sol:144` — `if (amountIn > params.amountInMaximum) revert V4TooMuchRequested(params.amountInMaximum, amountIn);`, combined with the mandatory `maxDebtIn` check at `src/MarginRouter.sol:420` and the borrow-equals-swap-input wiring at `:475`/`:576`.

### R-02 — [REFUTED, was High] `decreasePosition` passes an unvalidated adapter into `ACCOUNT_REPAY` and `ASSERT_HEALTH`, letting a malicious adapter divert swapped debt tokens and defeat the caller's own health bound

**Claim (agent: `invariants`).** `decreasePosition` never calls `_requireAllowedAdapter`, and the same caller-supplied adapter drives `positionOf` (`src/MarginRouter.sol:171`), `ACCOUNT_REPAY` (`:232`), `ACCOUNT_WITHDRAW_COLLATERAL` (`:233-238`), and `ASSERT_HEALTH` (`:240`). `MarginAccount.repay` (`src/MarginAccount.sol:107-117`) approves the adapter-chosen target for up to the account's full debt-token balance (`:111`) and executes adapter-chosen calldata against it with no target validation — unlike `withdrawCollateral`/`borrow`/`sweep`, which perform a separate hardcoded transfer after `_requireReceiver`. So a malicious frontend can have a victim sign a `decreasePosition` that diverts the debt tokens the real swap just bought while self-reporting a healthy LTV.

**Refutation.** Observations accurate; `repay` genuinely has no target check and no after-the-fact safety net. Not a novel finding, for four independent reasons.

1. **This *is* accepted decision #5, restated.** "SUPPLY_COLLATERAL and BORROW require an allowlisted adapter; WITHDRAW, REPAY, ACCOUNT_SWEEP do not, so a position is always exitable" — the absence of the check on the REPAY leg is that decision, echoed in the code at `src/MarginRouter.sol:567-568`.
2. **The capability is strictly subsumed by accepted decision #2.** `MarginAccount.execute` (`src/MarginAccount.sol:128-138`) is gated only by `msg.sender != ownerAddr` (`:134`) — the victim EOA — takes an owner-chosen adapter, and forwards fully arbitrary calldata plus arbitrary `msg.value` to `adapter.lendingProtocol()` (`:135-136`). The claim's threat model is "a malicious frontend induces the victim to sign attacker-chosen calldata." Under that identical precondition the attacker would simply have the victim sign `MarginAccount.execute(evilAdapter, transfer(attacker, balance))`, which needs no swap, no pool, and no health spoofing, and reaches strictly more value. The claimed path grants the signer nothing they do not already possess by design.
3. **Blast radius is hard-confined to the signer.** `src/MarginRouter.sol:170` derives the account as `accountOf(msgSender(), params.subId)`, and `msgSender()` is `_getLocker()` (`:381-383`), never calldata. `decreasePosition` pulls nothing from any EOA, so no third party is reachable. Nor can a hostile adapter siphon the router: the residual forwarded at `:248-249` is measured against `balanceBefore` snapshotted at `:244` *before* `poolManager.unlock`, so pre-existing router balances are excluded.
4. **The headline (full-close) form of the exploit fails at its own step 3.** With `debtToRepay = type(uint256).max`, `ACCOUNT_WITHDRAW_COLLATERAL` is encoded for the full `collateralBefore` (`src/MarginRouter.sol:236`); if `encodeWithdrawCollateral` points at the real protocol as the claim requires, the protocol reverts on its own health check because the debt was diverted rather than repaid; if the adapter instead fakes the withdraw, the router holds no collateral and the `SETTLE` of collateral `OPEN_DELTA` (`:239`) fails, unwinding the unlock. Only a partial decrease within the protocol's own withdrawal headroom completes, and its loss is bounded by `maxCollateralIn`, which the victim signs and which `:197` forces non-zero.

**Verdict: REFUTED.** What survives is the documentation defect plus the missing hardening check — filed as **L-03**.

**Decisive line:** `src/MarginAccount.sol:135-136` — the owner-only escape hatch already grants the account owner strictly more power than the claimed hostile-repay primitive.

### R-03 — [REFUTED, was Medium] `MarginAccount` never validates the adapter-returned call target, so an unallowlisted adapter passed to `decreasePosition` is an arbitrary-call primitive on the account

**Claim (agent: `first-principles`).** The four primitives pass `(target, value, callData)` straight to `_execCall` → `Address.functionCallWithValue` (`src/MarginAccount.sol:182-183`) with no comparison to `adapter.lendingProtocol()`; `lendingProtocol()` is read only in the owner-only `execute` (`:135`). `receive()` at `:187` makes the account able to hold native, contradicting `:178-179`. A victim submitting a `decreasePosition` naming an attacker's adapter loses the entire sub-account.

**Refutation.** All mechanical facts confirmed, including the dead `forcedTarget` hook (`test/mocks/MockLendingAdapter.sol:19-33`, never called) and the inaccurate claim at `src/interfaces/IMarginRouter.sol:270`. Refuted on **reachability, not pattern**.

The exploit requires the *victim* to submit `decreasePosition` naming the attacker's adapter. `src/MarginRouter.sol:170` derives the account as `accountOf(msgSender(), params.subId)`, and `msgSender()` is `_getLocker()` (`:381-383`), which `ReentrancyLock.isNotLocked` sets to `msg.sender` (`src/base/ReentrancyLock.sol:10-15`). There is no signature-relayed sender anywhere in the path — `Permit2Forwarder` forwards only token permits — so the caller is always the account's soulbound owner, who can already call `MarginAccount.execute(anyAdapter, anyCalldata)`. Accepted decision #2 states this verbatim.

Checked separately whether a hostile adapter can reach beyond the caller's own sub-account, and found no path: the arbitrary call executes as the *account*, which holds no PoolManager credit (a `take` by the account would leave a nonzero delta and revert the unlock) and holds no allowance from the router (`src/MarginRouter.sol:629-635` transfers directly, never approves). Re-entering `MarginRouter.execute` reverts `ContractLocked`. Router residual is accepted decision #1. In the swap-free branch the claim exploits (`src/MarginRouter.sol:175-193`), the function returns at `:193` before any residual transfer.

**Verdict: REFUTED.** Corrected severity Informational; the surviving substance is filed as **L-03**.

**Decisive line:** `src/MarginRouter.sol:170` — `account = accountOf(msgSender(), params.subId);` with `msgSender()` = `_getLocker()`.

### R-04 — [REFUTED, was Medium] Adapter market de-registration bricks every curated and plan-based exit path, falsifying "a position must always be exitable"

**Claim (agent: `first-principles`).** Same mechanism as L-01, filed independently, but asserting that de-registration *bricks* every router-mediated exit including `execute` plans (because `MarginAccount.repay`/`withdrawCollateral` call the gated encoders), and that the `MarginAccount.execute` recovery path "is nowhere documented as the exit of last resort and no frontend supports it".

**Refutation.** The mechanics are quoted correctly and are the same ones L-01 confirms. This *variant* is refuted on three grounds.

1. **Its central impact sentence is factually false.** `src/interfaces/IMarginAccount.sol:138-140` says the opposite, verbatim: "Owner-only escape hatch. Runs an adapter-encoded call against the adapter's lending protocol as this account, so the owner can **always close a position or recover funds** without involving the manager." That is precisely the documented exit of last resort, and it is registry-free (`src/MarginAccount.sol:135` reads only `lendingProtocol()`, ungated at `src/AaveLendingAdapter.sol:105-107`).
2. **No invariant is falsified; the claim conflates two curation layers the code keeps distinct.** The router's guarantee is explicitly scoped to "removed **from the allowlist**" (`src/interfaces/IMarginRouter.sol:267-269`), and that remains true. The adapter's per-market registry is a separately documented layer whose reverting behavior on unrouted pairs is stated as an interface-level contract at `src/interfaces/ILendingAdapter.sol:18-20` and again at `src/AaveLendingAdapter.sol:46-47`. Likewise the Morpho re-point is documented design: `src/types/MarketRegistry.sol:28` says "Registers (**or replaces**)", and `src/MorphoLendingAdapter.sol:225` and its `MarketSet` doc at `:51-52` repeat it.
3. **It is not bricking and not irreversible** — the only category accepted decision #6 admits for a governance-precondition finding. `src/AaveLendingAdapter.sol:268` writes unconditionally, so one owner call restores every path; `src/AaveV4LendingAdapter.sol:314-316` re-writes the route; `src/MorphoLendingAdapter.sol:234` re-registers. No position state is destroyed — collateral and debt live in the venue. And the ability to reverse can never be lost: `src/base/OwnableAdapter.sol:48` documents that the zero address is rejected "so the role cannot be bricked".

**Verdict: REFUTED as filed.** The underlying mechanism is real and is reported once, at correctly-scoped severity, as **L-01**. R-04's contribution is that the same mechanism was found independently by a second lens, which is why L-01 carries `[agents: 2/8]`.

**Decisive line:** `src/interfaces/IMarginAccount.sol:139` — "so the owner can always close a position or recover funds without involving the manager."

### R-05 — [REFUTED, was Medium] An event-only `describePosition` read sits on the critical path of `addCollateral`, so the emergency top-up reverts during an oracle outage

**Claim (agent: `first-principles`).** `addCollateral` completes its real work at `src/MarginRouter.sol:312` and then calls `describePosition` at `:313` purely to populate the event; if that oracle-dependent read reverts, the supply is undone. Same pattern at `:129` and `:269`. Supplying collateral needs no price on any venue, and this is precisely the window in which users must top up to avoid liquidation.

**Refutation.** All mechanical quotes accurate — the revert would happen. The *impact*, which is the entire basis for Medium, is refuted.

1. **The load-bearing premise is false.** The claim asserts `addCollateral` is "the only guard-railed way to rescue a position from liquidation" and that the only workaround is an unguarded hand-built `execute` plan. `MarginAccount.supplyCollateral` (`src/MarginAccount.sol:47`) is gated by `_authCaller`, whose check at `:155` is `if (msg.sender != managerAddr && msg.sender != ownerAddr)` — **the position owner may call it directly**, and `src/interfaces/IMarginAccount.sol:84-85` documents this as first-class ("Callable by the manager or owner"). It is a typed single-purpose function that constrains target, value, and resets the approval (`src/MarginAccount.sol:54-56`), not a hand-built plan, and it is entirely oracle-free (`src/CompoundV3LendingAdapter.sol:121-129`, `src/MorphoLendingAdapter.sol:81-88` do a registry read plus an `abi.encodeCall`). The emergency top-up during an outage is a token transfer to the deterministic account address (`src/MarginRouter.sol:339-346`) followed by `account.supplyCollateral(...)`.
2. **The full-exit path is also oracle-free**, so the position is never trapped. A full close reads only `positionOf` (`src/MarginRouter.sol:171`, price-free on Comet per `src/CompoundV3LendingAdapter.sol:192-193`), deliberately skips `describePosition` (`:254-267`), and passes `Ltv.wrap(0)` (`:240`), which `ASSERT_HEALTH` short-circuits at `:587` so `currentLtvWad` is never called.
3. **The claimed harm window does not exist.** The same read that blocks `describePosition` blocks the venue's own liquidation — Comet's `absorb`, Morpho's `liquidate`, and Aave's `liquidationCall` all price against the same feed. Once the feed recovers, `describePosition` recovers at the same instant liquidation becomes available. There is no interval in which a user can be liquidated but cannot top up.

**Verdict: REFUTED.** Corrected severity Informational (wrap the event read in `try`/`catch`, or drop the priced fields) — a robustness nit, not an availability defect. Not filed separately; the underlying "events carry priced fields the router does not need" theme is covered by L-08's recommendation.

**Decisive line:** `src/MarginAccount.sol:155` — `if (msg.sender != managerAddr && msg.sender != ownerAddr) NotAuthorized.selector.revertWith();`, which gives the owner a direct, typed, oracle-free top-up.

---

## Appendix D — Mitigated-pattern coverage

Deduplicated from all eight agents' `mitigated` lists. Each row is a pattern that was actively hunted and found correctly handled, with the specific line that handles it. This is the substance of the "codebase is in good shape" claim: it records what was *checked and cleared*, not merely what was not found.

Where more than one agent reached the same conclusion independently, the agent count is given.

### D.1 Reentrancy and call-flow isolation

| Pattern | Why it is safe | Agents |
|---|---|---|
| Malicious caller-chosen v4 hook, or a hostile adapter, re-entering the router's fund-moving entry points during the unlock | All four entry points carry `isNotLocked` (`src/MarginRouter.sol:121`, `:157`, `:290`, `:327`) and the Locker stays set for the whole body including the unlock (`src/base/ReentrancyLock.sol:10-15`), so re-entry reverts `ContractLocked`. `multicall` is unguarded but its legs are not. `unlockCallback` is `onlyPoolManager` (`src/base/SafeCallback.sol:15`). A nested `poolManager.unlock` is rejected by v4-core. The only unlocked reachable functions are views, `createAccount` (idempotent, owner-bound), the governance setters (`msg.sender`-gated), and `Permit2Forwarder.permit` (signature-gated). | 4/8 |
| Reentrancy from the lending protocol while a live ERC-20 approval is outstanding | Both approval-bearing primitives bracket the call and reset to zero in the same frame: `src/MarginAccount.sol:54-56` and `:112-114`. `withdrawCollateral` and `borrow` set no approval at all. The Morpho encoders pass empty callback data (`""` at `src/MorphoLendingAdapter.sol:87`, `:134`, `:136`), so Morpho's supply-collateral and repay callbacks never fire. | 2/8 |
| `_setApproval` left non-zero because the protocol call reverted | `_execCall` uses `Address.functionCallWithValue` (`src/MarginAccount.sol:183`), which bubbles the revert, and neither `supplyCollateral` nor `repay` wraps it in `try`/`catch` — so a failing call unwinds the frame containing the `forceApprove`. The only residual risk is a token that reverts on a zero-value `approve`, excluded by the curated-ERC20 boundary. | 1/8 |
| Malicious adapter mutating state or reentering during a read/encode | Every `ILendingAdapter` function is declared `view` (`src/interfaces/ILendingAdapter.sol:40-127`), so Solidity emits `STATICCALL`. A caller-supplied adapter's only influence is its return bytes. | 2/8 |
| Hook draining or inflating the router's PoolManager delta so a settle/take mis-accounts | v4-core's `take`/`burn`/`mint`/`clear`/`donate` all debit `msg.sender`, so a hook can only ever *credit* the router (via `settleFor`), never make it owe more. `_getFullCredit` reverts `DeltaNotPositive` on the wrong sign (`src/base/DeltaResolver.sol:74`) and `_getFullDebt` reverts `DeltaNotNegative` (`:63`), so a sign flip fails closed. Hook-charged fees are inside the returned `BalanceDelta`, so `amountInMaximum` still binds at `src/V4Router.sol:144`. | 2/8 |
| Hook flipping the input delta positive to bypass the input cap | `_swapInput` computes `uint256(-int256(delta))` then `.toUint128()` (`src/V4Router.sol:207-208`), so a positive input delta triggers a `SafeCast` revert rather than bypassing `amountInMaximum`. | 1/8 |

### D.2 Account authority and access control

| Pattern | Why it is safe | Agents |
|---|---|---|
| Active account or Permit2 payer sourced from calldata (account substitution, or pulling from a third party) | The active account is only ever `createAccount(msgSender(), subId)` (`src/MarginRouter.sol:423`, `:540`, `:295`) or `accountOf(msgSender(), subId)` (`:170`), and `msgSender()` returns `_getLocker()` (`:381-383`), set from `msg.sender` by `isNotLocked`. Every Permit2 pull uses `msgSender()` as payer (`:308`, `:437`, `:599`, and `:633` via `_mapPayer`, `src/base/BaseActionsRouter.sol:72-74`). No decoder in `MarginCalldataDecoder` returns an account or payer address — `decodeHealthCheck`'s NatSpec at `src/libraries/MarginCalldataDecoder.sol:54-56` states the account is deliberately not encoded. | 5/8 |
| Third-party access to another user's `MarginAccount` | `_authCaller` admits only the clone's baked-in manager or owner (`src/MarginAccount.sol:153-156`), read from immutable args (`:146`) with no setter. `MarginAccount.execute` narrows further to owner-only (`:133-134`), and the router never calls it (grep-confirmed: the router's only account calls are `supplyCollateral`, `withdrawCollateral`, `borrow`, `repay`, `sweep`). | 4/8 |
| Adapter-encoded bytes redirecting withdrawn or borrowed funds | `_requireReceiver` (`src/MarginAccount.sol:163-165`) is enforced by the account against its own immutable owner/manager *before* the encoder's output is executed, in `withdrawCollateral` (`:73`) and `borrow` (`:94`), and again in `sweep` (`:122`). The router supplies the receiver itself (`src/MarginRouter.sol:570`, `:577`). Note this is the *one* authority-bearing field the account actually owns — the target is not (L-03). | 3/8 |
| `ACTIVE_ACCOUNT_SLOT` leaking across `multicall` legs, or surviving a mid-plan revert | Every path that sets it clears it: `_increase` (`src/MarginRouter.sol:424` → `:483`), `decreasePosition` (`:199` → `:246`), `execute` (`:333`). The debt-free full-close returns at `:193` *before* `:199`, so it never sets it; `addCollateral` never sets it. The `NoActiveAccount` guard at `:554-555` backstops. Revert-survival was settled by construction rather than assumed: grep proves no `try`/`catch` exists around any unlock in scope (the only two in the whole margin surface are `src/base/Permit2Forwarder.sol:23`/`:36` and `src/CompoundV3LendingAdapter.sol:290-294`, neither touching the account), so `tstore` unwinds with the frame. Pinned by `test/integration/MarginRouterExecute.t.sol:248-266`. | 3/8 |
| Active account reachable outside an unlock | `_activeAccount()` (`src/MarginRouter.sol:651-656`) is read at exactly one site, `:554`, inside `_handleAction`, reachable only from `_executeActionsWithoutUnlock` → `_unlockCallback` → `SafeCallback.unlockCallback`, which is `onlyPoolManager` (`src/base/SafeCallback.sol:15`). | 1/8 |
| CREATE2 address squatting / pre-deploying someone else's account to hijack it | The salt binds the owner (`src/MarginAccountFactory.sol:81`) and `(owner, manager)` are baked into the clone's immutable args (`:70-72`), read back via `LibClone.argsOnClone` (`src/MarginAccount.sol:146`), so deploying at a victim's predicted address installs the *victim* as owner. `abi.encode` (not `encodePacked`) with fixed-size inputs rules out salt ambiguity. `createAccount` is idempotent (`:60-63`), so a lost lazy-deploy race returns the existing account. No initializer and no ownership-transfer path exist, so there is nothing to front-run. | 4/8 |
| `accountOf` / `createAccount` deriving different addresses (args, salt, or deployer mismatch) | Both call sites use the identical `_args(owner)` and `_salt(owner, subId)` (`src/MarginAccountFactory.sol:47-49`, `:61`) and CREATE2 from `address(this)`. In solady 0.1.26, `predictDeterministicAddress` hashes exactly the initcode `cloneDeterministic` deploys, and `argsOnClone` reads from the offset matching that initcode's runtime prefix. `manager` is fixed to `address(this)` at construction (`:37`), so the owner cannot vary it. | 1/8 |
| Two-step ownership/governance handoff bricked, hijacked, or accepted with nothing pending | `write` and `propose` both reject the zero address (`src/types/Owner.sol:51`, `:71`), so the role can never be transferred to an unrecoverable address. `acceptOwnership` requires `caller == self._pending` (`:84`), and because a real external call's `msg.sender` is never `address(0)`, that single check also rejects an accept with nothing pending — documented in the comment at `:82-83`. The current holder keeps its powers until acceptance, and reverts leave `_current` untouched. Used identically by the router (`src/MarginRouter.sol:364-368`, `:391-406`) and every adapter (`src/base/OwnableAdapter.sol:42-53`). | 5/8 |
| Adapter market curation bypass, or an adapter deployed with an unset owner | All four `setMarket` implementations call `_onlyOwner()` as their first statement (`src/MorphoLendingAdapter.sol:231`, `src/AaveLendingAdapter.sol:262`, `src/AaveV4LendingAdapter.sol:301`, `src/CompoundV3LendingAdapter.sol:286`), and the router's `setAdapterAllowed`/`transferGovernance` call `_governance.onlyOwner(msg.sender)` first (`src/MarginRouter.sol:392`, `:403`). Every adapter constructor seeds a non-zero owner via `OwnableAdapter(owner_)` → `Owner.write` (`src/base/OwnableAdapter.sol:22`), which itself rejects zero. | 2/8 |
| The manager (router) reaching the owner-only `MarginAccount.execute` escape hatch, extending its blast radius | `src/MarginAccount.sol:134` checks `msg.sender != ownerAddr` only — the manager branch present in `_authCaller` is deliberately absent — and grep confirms the router never calls `IMarginAccount.execute` anywhere. | 1/8 |
| Router residual as a *shared* pot across users | Curated flows net to zero by construction, and `decreasePosition` measures and forwards its residual synchronously inside the same call (`src/MarginRouter.sol:244`, `:248-249`), so no cross-transaction window exists. `execute` plans can direct funds only to the account's own owner (== the real caller) or the manager, per `_requireReceiver`. Any router-resident balance is therefore always self-inflicted by the depositor's own unswept plan — exactly the accepted boundary at `src/interfaces/IMarginRouter.sol:311-313`. | 3/8 |
| Initialization safety / proxy storage collision on `MarginAccount` | `forge inspect MarginAccount storage-layout` returns an **empty** layout — the account declares zero storage variables; `(owner, manager)` come from clone immutable args. No initializer, no double-init window, no implementation slot to collide. `MarginRouter` has exactly two storage variables, both written only behind the governance guard or the constructor, and neither contract is upgradeable. | 1/8 |

### D.3 Action dispatch and plan composition

| Pattern | Why it is safe | Agents |
|---|---|---|
| An opcode reaching a handler it should not, or falling through silently | The whole `0x00`–`0xff` space was enumerated against `src/MarginRouter.sol:505-607`. The interception window `action >= Actions.SWEEP && action <= Actions.UNWRAP` (`:511`) is exactly `{0x14, 0x15, 0x16}` per `src/libraries/Actions.sol:50-53`, and `test/libraries/MarginCalldataDecoder.t.sol:140-146` pins that contiguity against a future reordering. Margin opcodes start at `0x30` (`src/libraries/MarginActions.sol:20`), leaving `0x1c`–`0x2f` free, so no overlap with the core space ending at `0x1b`. `CLOSE_CURRENCY` (`0x12`) and `CLEAR_OR_TAKE` (`0x13`) fall through to `super._handleAction` and terminate at `revert UnsupportedAction` (`src/V4Router.sol:81`) — correct, since `MarginRouter` implements no `_close`/`_clearOrTake`. Above `0x38`, `src/MarginRouter.sol:604-606` reverts. `action` is `uint8` (`src/base/BaseActionsRouter.sol:44`), so the domain is closed. | 3/8 |
| Only `SET_ACCOUNT` and `ASSERT_FILL` bypassing the `NoActiveAccount` guard | Both are safe to bypass: `SET_ACCOUNT` derives from `msgSender()` (`src/MarginRouter.sol:540`) and `ASSERT_FILL` only reads the router's own credit (`:543-549`). | 1/8 |
| `SWEEP`/`WRAP`/`UNWRAP` interception diverging from `PositionManager` semantics | Byte-for-byte identical: `src/MarginRouter.sol:512-527` matches `src/PositionManager.sol:271-282`, and `MarginRouter._sweep` (`:614-617`) matches `PositionManager._sweep` (`:499-502`). | 1/8 |
| `abi.encode`/`abi.decode` tuple-shape disagreement across the nine margin opcodes | Every router encode site was cross-checked against `MarginCalldataDecoder`: `ACCOUNT_SUPPLY_COLLATERAL`/`ACCOUNT_REPAY` (`src/MarginRouter.sol:473`, `:232` ↔ `src/libraries/MarginCalldataDecoder.sol:22-28`); `ACCOUNT_WITHDRAW_COLLATERAL`/`ACCOUNT_BORROW` (`:233-238`, `:475` ↔ `:37-43`); `ASSERT_HEALTH` (`:240`, `:480` ↔ `:61-67`); `ASSERT_FILL` (`:230`, `:469` ↔ `:74-76`). `Market` is a two-static-field struct (`src/types/Market.sol:15-18`) so it encodes inline both ways, and `Ltv`/`Currency` are UDVTs over `uint256`/`address`. `ACCOUNT_SWEEP`, `SET_ACCOUNT`, and `PULL_TO_ACCOUNT` have no in-repo encoder, so no in-repo mismatch is possible. | 1/8 |
| `PULL_TO_ACCOUNT` smuggling the `CONTRACT_BALANCE` sentinel onto the caller's Permit2 allowance | A zero amount is rejected outright (`src/MarginRouter.sol:595`), and on the `payerIsUser` path the amount goes through `amount.toUint160()` (`:599`); `CONTRACT_BALANCE` is `1 << 255` (`src/libraries/ActionConstants.sol:13`), so the `SafeCast` reverts. The sentinel is honored only on the router-balance branch (`:601`). Reasoning documented inline at `:596-598` and in the interface at `src/interfaces/IMarginRouter.sol:317-320`. | 4/8 |
| Deadline omission / stale-transaction execution | `checkDeadline` (`src/MarginRouter.sol:86-89`) is applied to all four entry points (`:122`, `:158`, `:291`, `:327`). `multicall` carries no deadline of its own, but every leg that moves funds enforces its own. | 1/8 |
| Unbounded loops, external calls in loops, revert-on-transfer DoS | The only loops are over the caller's own action list (`src/base/BaseActionsRouter.sol:43-47`) and the caller's own `multicall` leg list (`src/base/Multicall_v4.sol:12-23`) — both caller-sized and gas-bounded. No per-user or per-market registry is ever iterated: adapters hold no arrays, and `MarketRegistry` plus the three allowlists are pure mappings (`src/types/MarketRegistry.sol:17`, `src/AaveLendingAdapter.sol:68`, `src/CompoundV3LendingAdapter.sol:67`, `src/AaveV4LendingAdapter.sol:81`). | 1/8 |

### D.4 Swap, fill, and settlement correctness

| Pattern | Why it is safe | Agents |
|---|---|---|
| Exact-output partial fill silently opening a smaller position or under-funding a repay | `ASSERT_FILL` runs between the swap and the `TAKE` in both curated plans (`src/MarginRouter.sol:446-448`, `:202-204`), checking `_getFullCredit(currency) >= minAmount` and reverting `IncompleteFill` (`:543-549`). `increasePosition` requires the full `collateralToBuy` (`:469`), `decreasePosition` the full repay amount (`:230`), making both all-or-nothing. | 3/8 |
| `ASSERT_FILL` and the following `TAKE` disagreeing on the amount | Both read the same `poolManager.currencyDelta(address(this), currency)` (`src/base/DeltaResolver.sol:61`, `:72`) with no intervening action in either curated plan, and `TAKE(..., OPEN_DELTA)` re-resolves through `_mapTakeAmount` → `_getFullCredit` (`src/V4Router.sol:73`, `src/base/DeltaResolver.sol:90-96`). An exact-output swap cannot over-deliver, so credit equals the asserted minimum. | 1/8 |
| Pool/market currency mismatch reaching the lending legs in the *curated* flows | Both flows derive `zeroForOne` only through `Market.toSwapParams` (`src/MarginRouter.sol:220`, `:443`), which asserts set-equality of `{currency0, currency1}` with `{collateral, debt}` (`src/types/Market.sol:70`) and that the input is one of the two (`:72`), reverting `MarketSwapMismatch`. `collateral == debt` is structurally impossible (it would require `currency0 == currency1`). Registry lookups are directional and never return a default (`src/types/MarketRegistry.sol:47-52`, `src/AaveLendingAdapter.sol:274-278`, `src/AaveV4LendingAdapter.sol:327-330`, `src/CompoundV3LendingAdapter.sol:302-306`). *Does not cover `execute` — see I-01.* | 3/8 |
| `decreasePosition` draining the router's pre-existing balance of the collateral token via the `SETTLE` leg | `uint256 residual = params.market.collateral.balanceOfSelf() - balanceBefore;` (`src/MarginRouter.sol:248`) is a checked subtraction against a snapshot taken *before* the unlock (`:244`), so a plan that pays out more collateral than it withdrew — a full close whose swap cost exceeds `collateralBefore`, or a caller-supplied fake adapter — underflows and reverts rather than consuming a stranded residual. It also cannot be mis-reported as realized PnL. | 4/8 |
| Discarded return bytes from the four account primitives hiding a partial success | No amount the router or account acts on comes from a protocol return value; each is independently measured — balance deltas (`src/MarginAccount.sol:78`, `:98`, `:115`) or the router's own PoolManager delta (`src/base/DeltaResolver.sol:60-76`). Checked per adapter: Morpho's `borrow`/`repay` return `(assets, shares)`, Aave v3's `withdraw`/`repay` return the actual amount, Comet's `supply`/`withdraw` return nothing — in every case a short delivery becomes a smaller measured delta, which then fails the downstream `SETTLE` or the underflow guard at `src/MarginRouter.sol:248`. | 1/8 |
| Balance-delta measurement misattributing a pre-existing account balance (stray transfer, prior partial flow, owner-sent tokens) | All three measurement sites are strict deltas across the protocol call, never absolute balances (`src/MarginAccount.sol:74`+`:78`, `:95`+`:98`, `:110`+`:115`). A pre-existing balance appears on both sides and cancels, so `borrow` cannot sweep a stray balance out to the receiver and a real borrow is not under-forwarded. | 1/8 |
| Lending-protocol health-check bypass via action ordering | Plans are ordered so the protocol's own solvency check is the binding one: increase does SUPPLY before BORROW (`src/MarginRouter.sol:449-451`), and both decrease modes do REPAY before WITHDRAW (`:205-207`). No plan withdraws collateral while the debt it backs is outstanding. | 2/8 |
| Full repay leaving borrow-share dust that fails the full-collateral withdrawal's health check | `decreasePosition` passes `type(uint256).max` on a full close (`src/MarginRouter.sol:232`) and each adapter maps it to a dust-free full repay: Morpho burns the exact `borrowShares` read from `morpho.position` (`src/MorphoLendingAdapter.sol:131-134`), Aave v3 forwards max so the Pool caps at the full variable debt (`src/AaveLendingAdapter.sol:176`), Aave v4's Spoke caps an over-amount at drawn-plus-premium (`src/AaveV4LendingAdapter.sol:200`), Comet supplies exactly the accrued `borrowBalanceOf` (`src/CompoundV3LendingAdapter.sol:178`). `MarginAccount.repay` approves the account's whole measured balance for the max case (`src/MarginAccount.sol:111`) and resets to zero (`:114`). | 4/8 |
| Interest accruing between the pre-unlock `positionOf` read and the in-unlock max repay, undersizing the close swap | Every full-close read previews interest live to the current block and happens in the *same transaction* as the repay, so accrual is identical: `MorphoBalancesLib.expectedBorrowAssets` (`src/MorphoLendingAdapter.sol:151`, Morpho's own canonical helper, not a reimplementation), live rebasing aToken/variable-debt `balanceOf` (`src/AaveLendingAdapter.sol:193-194`), `getUserTotalDebt` (`src/AaveV4LendingAdapter.sol:213-214`), `borrowBalanceOf` re-read at encode time (`src/CompoundV3LendingAdapter.sol:178`). Even a residual wei mismatch fails closed, because the approval is capped at the account's actual balance (`src/MarginAccount.sol:111`). | 3/8 |
| Native-currency handling: unexpected ETH, stray-ETH accumulation, wrong-collateral wrap | `NativeWrapper.receive` reverts `InvalidEthSender` for any sender other than WETH9 or the PoolManager (`src/base/NativeWrapper.sol:31-33`), so the router cannot be dusted. Both native-equity paths verify the market collateral is WETH before wrapping and forward the full amount immediately (`src/MarginRouter.sol:300-303`, `:432-434`), reverting `NativeCollateralMismatch` otherwise. `decreasePosition` is non-payable, so a valued `multicall` leg naming it reverts in the dispatcher. (The `msg.value`-per-leg question is LD-04.) | 3/8 |
| Non-standard ERC-20 semantics (USDT-style missing return value, approve-from-nonzero) | Approvals use OZ `SafeERC20.forceApprove` (`src/MarginAccount.sol:172`), which falls back to `approve(0)`-then-`approve`. Outbound transfers use v4-core `CurrencyLibrary.transfer` (`src/MarginAccount.sol:79`, `:99`, `:123`; `src/MarginRouter.sol:249`, `:303`, `:434`, `:602`, `:616`, `:631`), which accepts an empty return or an exact `1` and reverts `ERC20TransferFailed` otherwise, so a silently-failing transfer cannot pass. | 1/8 |

### D.5 Oracle, health, and economic

| Pattern | Why it is safe | Agents |
|---|---|---|
| Flash-loan manipulation of the value `ASSERT_HEALTH` reads | `currentLtvWad` is computed from each venue's own oracle, never from v4 pool spot: `src/MorphoLendingAdapter.sol:211`, `src/AaveLendingAdapter.sol:222`, `src/AaveV4LendingAdapter.sol:244`, `src/CompoundV3LendingAdapter.sol:228-229`. Since these are the same oracles the venues use for liquidation, a pool-spot flash loan cannot make an unhealthy position read healthy. (Residual question: I-07.) | 2/8 |
| Zero or stale oracle price making `ASSERT_HEALTH` pass on an unhealthy position | Fails safe in the reverting direction. A zero price gives `collateralValue == 0`, and every adapter's `_ltv` returns `type(uint256).max` when debt exists (`src/MorphoLendingAdapter.sol:221`, `src/AaveLendingAdapter.sol:223`, `src/AaveV4LendingAdapter.sol:282`, `src/CompoundV3LendingAdapter.sol:275`). `src/MarginRouter.sol:587` then reverts `PositionUnhealthy` for any non-zero bound. | 2/8 |
| `CompoundV3LendingAdapter.maxLtvWad` returning the *liquidate* factor while Comet enforces the tighter *borrow* factor | `ASSERT_HEALTH` never calls `maxLtvWad` — it compares `currentLtvWad` against the caller's bound only (`src/MarginRouter.sol:584-589`). The real gate is Comet's own synchronous check inside `withdraw`, which fires during `ACCOUNT_BORROW` (`:571-577`), i.e. strictly *before* `ASSERT_HEALTH`, and reverts the whole transaction. So a position Comet's borrow factor would reject can never be opened; the worst case is a legitimate revert. Documented at `src/CompoundV3LendingAdapter.sol:39-42`. Remains a frontend-sizing UX inconsistency (see I-05). | 1/8 |
| Third-party manipulation of a position to block a close or force a bad close | Nothing a third party can do worsens the position. On Morpho, `borrow` and `withdrawCollateral` require authorization while `supplyCollateral`/`repay` are gifts; on Aave v3/v4 and Comet, `borrow`/`withdraw` require delegation or `allow()`. A same-block front-running repay that zeroes the debt is handled: `decreasePosition` re-reads debt at `src/MarginRouter.sol:171` and routes a zero-debt full close down the swap-free path at `:175-193`, so the share-based repay is never called with zero shares. | 2/8 |
| Aave v3 zero-LTV reserve donation grief (third party supplies a `ltv == 0` collateral to a victim's account to force `LTV_VALIDATION_FAILED` on partial decreases) | **Empirically refuted on the live mainnet Pool.** The precondition holds — live `cast call` reads of the Aave v3 PoolDataProvider confirm 1INCH, BAL, CRV, SNX, LDO, ENS, FRAX, and LUSD all carry `ltv == 0` with a non-zero liquidation threshold and `usageAsCollateralEnabled == true` — but a mainnet fork test showed that after an attacker's `pool.supply(1INCH, 1e18, victim, 0)` the victim's `getUserConfiguration` was unchanged (the 1INCH collateral bit was not auto-enabled) and the victim's `pool.withdraw` still succeeded. Current Aave requires `onBehalfOf == msg.sender` for automatic collateral enablement. **Caveat: this is a protocol-side mitigation outside the audited code**, so it warrants a fork regression test in `test/fork/AaveLendingAdapter.fork.t.sol` to catch an Aave upgrade that reintroduces it. | 1/8 |
| Full-close residual (realized PnL) claimed by a third party | Computed and transferred to `msgSender()` inside the same `decreasePosition` call (`src/MarginRouter.sol:244-249`), atomically, before the function returns. `ReentrancyLock` uses a single global transient slot, so no two guarded entry points can interleave within one transaction. | 2/8 |

### D.6 Arithmetic, scale, and sentinels

| Pattern | Why it is safe | Agents |
|---|---|---|
| Aave v4 `collateralFactor` treated as basis points (suspected scale bug) | Not a bug: `DynamicReserveConfig.collateralFactor` is `uint16` and documented "in basis points (1e4 == 100%)" at `src/interfaces/external/aave-v4/ISpoke.sol:55-60`, so `collateralFactor * WAD / BPS` (`src/AaveV4LendingAdapter.sol:227`, `:268`) is the correct conversion. The WAD-scaled `avgCollateralFactor` (`ISpoke.sol:68`) is deliberately not used. | 1/8 |
| Aave v4 `totalCollateralValue * RAY` phantom overflow in `_currentLtv` | `src/AaveV4LendingAdapter.sol:283` multiplies before dividing, but Value units are USD × 1e8 (`src/interfaces/external/aave-v4/ISpoke.sol:70-71`), so overflow needs `totalCollateralValue > 2^256/1e27 ≈ 1.16e50`, i.e. ~$1.2e42 on one Spoke. The numerator is handled in 512-bit by `Math.mulDiv`, so there is no precision loss either. | 1/8 |
| Aave v3 BPS vs WAD mixing | `liquidationThreshold * WAD / BPS` (`src/AaveLendingAdapter.sol:205`, `:248`) matches the declared units: index 3 of `getUserAccountData` is "The weighted-average liquidation threshold (basis points)" (`src/interfaces/external/aave/IPool.sol:53`) and index 5 `healthFactor` is declared WAD (`:55`) and assigned to a WAD field. The tuple destructurings at `src/AaveLendingAdapter.sol:203-204` and `:241-242` line up with the declarations. | 1/8 |
| Decimal mismatch between 6-decimal USDC collateral and 18-decimal WETH debt (and the reverse) in LTV math | No adapter mixes raw amounts of the two tokens. Morpho values collateral into loan-token units via the 1e36-scaled oracle before dividing (`src/MorphoLendingAdapter.sol:211`, `:222`); Aave v3 divides two base-currency USD totals (`src/AaveLendingAdapter.sol:224`); Aave v4 divides two Value-unit totals (`src/AaveV4LendingAdapter.sol:283`); Compound divides two USD values each normalised by its own asset scale (`src/CompoundV3LendingAdapter.sol:256-257`, `:265-267`). The router's only cross-value arithmetic is same-currency (`src/MarginRouter.sol:137`, `:248`, `:276`). | 1/8 |
| Compound price-scale cancellation across two different feeds | `_usd` divides by the asset's own `scale` and multiplies by its own feed price (`src/CompoundV3LendingAdapter.sol:265-267`), so the ratio in `_ltv` cancels **only if both feeds share a scale**. This holds for the live cUSDCv3 deployment (`src/interfaces/external/compound-v3/IComet.sol:20-21` documents the 1e8 price scale). ⚠️ **Downgraded during report assembly** (see B.3): the vendored interface does *not* record a constructor check rejecting non-8-decimal feeds, Comet source is out of scope, and the adapter never re-validates feed decimals for the Comet it binds at `src/CompoundV3LendingAdapter.sol:100-105`. Same root cause as L-04; the construction-time check recommended there addresses both. | 1/8 |
| Rounding direction and phantom overflow in the LTV / health math generally | Multiplication precedes division throughout (`src/AaveLendingAdapter.sol:205`, `src/AaveV4LendingAdapter.sol:227`, `src/MorphoLendingAdapter.sol:222`). The products that could phantom-overflow use 512-bit `Math.mulDiv`: collateral × the 1e36 Morpho oracle price (`src/MorphoLendingAdapter.sol:211`, with the reasoning in the comment at `:209-210`), the Comet USD valuations (`src/CompoundV3LendingAdapter.sol:266`), and the Aave v4 RAY-scaled ratio (`src/AaveV4LendingAdapter.sol:283`). LTV rounds down, favouring the caller by at most 1 wei of WAD. Morpho's one raw multiplication (`:222`) needs debt > ~1.16e59 base units to overflow. | 2/8 |
| `SafeCast` narrowing of protocol-read debt to `uint128` on a full close | `(fullClose ? debt : params.debtToRepay).toUint128()` (`src/MarginRouter.sol:221`) uses v4-core `SafeCast`, which reverts rather than truncating. `uint128` max is 3.4e38 (3.4e32 USDC, 3.4e20 WETH); Morpho's borrow accounting is itself `uint128`-bounded and Comet's `borrowBalanceOf` derives from a `uint104` principal, so no curated market approaches the boundary. | 1/8 |
| `type(uint256).max` sentinel collision between full-close, repay-all, and the undercollateralized `Ltv` return | The three meanings never meet on one value. `debtToRepay == max` selects the full-close branch (`src/MarginRouter.sol:161`) and is the only value reaching `encodeRepay` as the repay-all sentinel (`:232`). A `currentLtvWad` of max is consumed only by `.gt(maxLtv)` in `ASSERT_HEALTH` (`:587`), where it fails safe for every bound below max; a full close passes `Ltv.wrap(0)` (`:240`), which skips the check. | 1/8 |
| `minHopPriceX36` X36 fixed-point overflow | `uint256(amountOut) * PRECISION` (`src/V4Router.sol:148`, `:95`) is at most `(2^128-1) * 1e36 ≈ 3.4e74 < 2^256`, because both output helpers narrow to `uint128` first (`src/V4Router.sol:207-216`), so it cannot overflow even inside the `unchecked` multi-hop loops. | 1/8 |
| Adapter registries returning a silent default market for an unregistered pair | Morpho: `resolve` reverts when both tokens are zero (`src/types/MarketRegistry.sol:47-52`) and every encode/read goes through it. Aave v3: `_requireSupportedMarket` (`src/AaveLendingAdapter.sol:274-278`) is the first statement in all six encode/read functions. Aave v4: `_resolveRoute` reverts unless `route.registered` (`src/AaveV4LendingAdapter.sol:327-330`). Comet: `_requireSupportedMarket` (`src/CompoundV3LendingAdapter.sol:302-306`). Registration is additionally validated onchain in every adapter (`src/MorphoLendingAdapter.sol:233`, `src/AaveLendingAdapter.sol:264-266`, `src/AaveV4LendingAdapter.sol:303-313`, `src/CompoundV3LendingAdapter.sol:288-294`). *This same strictness is what produces L-01 on the exit path.* | 3/8 |

### D.7 Vendored-ABI agreement (checked field-by-field)

| Venue | Verified against | Result |
|---|---|---|
| Morpho Blue | `lib/morpho-blue/src/interfaces/IMorpho.sol` | `supplyCollateral(marketParams, assets, onBehalf, data)` ↔ `src/MorphoLendingAdapter.sol:87`; `withdrawCollateral(marketParams, assets, onBehalf, receiver)` ↔ `:103`; `borrow(marketParams, assets, shares, onBehalf, receiver)` ↔ `:117` (asset-denominated, `shares = 0`, delivered to the account); `repay(marketParams, assets, shares, onBehalf, data)` ↔ `:134` (full: `assets = 0`, `shares = borrowShares`) and `:136` (partial). Morpho's own docs recommend the share input for a full repay, which is exactly what `:131-134` does. |
| Aave v3 | `src/interfaces/external/aave/IPool.sol` | `supply(asset, amount, onBehalfOf, referralCode)` ↔ `src/AaveLendingAdapter.sol:124`; `withdraw(asset, amount, to)` ↔ `:142`; `borrow(asset, amount, interestRateMode, referralCode, onBehalfOf)` ↔ `:158` with `VARIABLE_RATE = 2` (`:55`, matching `IPool.sol:29`); `repay(asset, amount, interestRateMode, onBehalfOf)` ↔ `:176`. The 6-tuple order of `getUserAccountData` (`IPool.sol:56-66`) matches the destructurings at `:222` and `:241-242`. |
| Aave v4 | `src/interfaces/external/aave-v4/ISpoke.sol` + `test/fork/AaveV4LendingAdapter.fork.t.sol` | `encodeSupplyCollateral` returns `target = address(spoke)` (`src/AaveV4LendingAdapter.sol:157`) and the account approves exactly that (`src/MarginAccount.sol:54`); `ISpoke.multicall` is a delegatecall-to-self preserving `msg.sender` (`ISpoke.sol:140-144`), so the Spoke is both the caller's context and the token spender. Struct field ordering (`Reserve`, `DynamicReserveConfig`, `UserAccountData`) — a wrong order would silently corrupt `collateralFactor`/`healthFactor`/`totalDebtValueRay` — is pinned by the fork test: USDC collateral factor asserted as 7800 bps (`test/fork/AaveV4LendingAdapter.fork.t.sol:60-61`) and `healthFactorWad > 1e18` on a live position (`:164`). `setMarket` additionally re-validates `reserve.underlying` and `reserve.hub` onchain before registering (`src/AaveV4LendingAdapter.sol:303-313`). |
| Compound v3 | `src/interfaces/external/compound-v3/IComet.sol` + `test/fork/CompoundV3LendingAdapter.fork.t.sol` | `supply(asset, amount)` (`IComet.sol:46`) used for both collateral supply (`src/CompoundV3LendingAdapter.sol:128`) and repay (`:179`); `withdraw(asset, amount)` (`IComet.sol:50`) draws the borrow (`:162`); `withdrawTo(to, asset, amount)` (`IComet.sol:52-53`) argument order matches `:147`. The single-base constraint is enforced at construction (`:100-105`) and in `setMarket`, which reverts `DebtNotBaseToken` unless `debt == baseToken` (`:288`) and requires the collateral to be a registered Comet asset via `try`/`catch` on `getAssetInfoByAddress` (`:290-294`). Dust-free full repay pinned at `test/fork/CompoundV3LendingAdapter.fork.t.sol:163`. |

### D.8 Minor items observed and deliberately not filed

- `MarginAccount.borrow` transfers unconditionally at `src/MarginAccount.sol:99` while `withdrawCollateral` guards on non-zero at `:79` — unreachable asymmetry, since a zero-amount borrow reverts inside every lending protocol first.
- `supplyCollateral` returns `amount` rather than a measured delta (`src/MarginAccount.sol:58`), so a protocol supplying less than requested would overstate the `CollateralSupplied` event. Excluded by the curated-ERC20 boundary (accepted decision #4).
- `AaveLendingAdapter.setMarket` and `MorphoLendingAdapter.setMarket` do not reject `collateral == debt` — unswappable in v4 regardless, since `Market.toSwapParams` would require `currency0 == currency1`.
- Two speculative avenues traced but not concluded, and deliberately not filed: (a) a caller-chosen malicious hook mutating Morpho market totals mid-swap so a full-close repay comes up 1 wei short — self-inflicted DoS only, since the victim chooses the pool; (b) markets registered with a zero-address (native) token, which every adapter's `setMarket` validation appears to reject and which is governance-gated regardless.
- Aave v3 isolation-mode / automatic-use-as-collateral behavior on a *future* allowlisted asset, and Comet's `baseBorrowMin` floor on small increases, are both revert-only paths noted but not pursued.

---

## Appendix E — Agent attribution

### E.1 Findings by originating agent

| ID | Severity | Title (abbreviated) | Originating agent(s) | Verdict |
|----|----------|---------------------|----------------------|---------|
| L-01 | Low | Adapter per-market de-registration degrades the curated exit path | `invariants`, `first-principles` | CONFIRMED |
| L-02 | Low | `CollateralWithdrawn.amount` always zero on 3 of 4 adapters | `periphery` | UNVERIFIED |
| L-03 | Low | `target == lendingProtocol()` / `value == 0` invariant unenforced | `execution-trace`, `vector-scan`, `periphery` | UNVERIFIED |
| L-04 | Low | Comet `describePosition` divides by a value it did not guard | `math-precision` | UNVERIFIED |
| L-05 | Low | Unvalidated `poolKey.hooks` makes event prices caller-controlled | `first-principles` | UNVERIFIED |
| L-06 | Low | `OPEN_DELTA == 0` sentinel collision on a zero-collateral full close | `first-principles` | UNVERIFIED |
| L-07 | Low | `debtToRepay` never bounded by the debt just read | `math-precision`, `vector-scan` | UNVERIFIED |
| L-08 | Low | Full-close event asserts an empty position without reading back | `first-principles` | UNVERIFIED |
| I-01 | Info | `toSwapParams` choke-point claim does not cover `execute` | `vector-scan` | UNVERIFIED |
| I-02 | Info | `_pay` unchecked `uint160` cast | `vector-scan` | UNVERIFIED |
| I-03 | Info | `IComet` NatSpec contradicts the full-repay argument | `periphery` | UNVERIFIED |
| I-04 | Info | `createAccount` permissionless with arbitrary `owner` | `vector-scan`, `access-control` | UNVERIFIED |
| I-05 | Info | `healthFactorWad` not the documented identity on Aave | `math-precision` | UNVERIFIED |
| I-06 | Info | The `0` sentinel means four things across the opcodes | `execution-trace` | UNVERIFIED |
| I-07 | Info | `maxLtvAfter` bounded by venue oracle resistance | `economic` | UNVERIFIED (out of scope) |
| LD-01 | Lead | Aave v4 blocklisted-account collateral freeze | `periphery` | conf 62 |
| LD-02 | Lead | `_increase` has no router-balance conservation guard | `vector-scan`, `execution-trace` | conf 55 |
| LD-03 | Lead | Residual bad-debt position breaks the full-close swap | `economic` | conf 55 |
| LD-04 | Lead | `msg.value` re-observed by every `multicall` leg | `execution-trace` | conf 55 |
| LD-05 | Lead | Aave v3 data provider cached immutably with no setter | `periphery` | conf 55 |
| LD-06 | Lead | Aave v4 partial-decrease share-rounding shortfall | `vector-scan` | conf 45 |
| R-01 | *refuted* | `maxLtvAfter` optional on increase (was High) | `economic` | REFUTED |
| R-02 | *refuted* | Unvalidated adapter into `ACCOUNT_REPAY` (was High) | `invariants` | REFUTED |
| R-03 | *refuted* | Unvalidated call target = arbitrary call (was Medium) | `first-principles` | REFUTED |
| R-04 | *refuted* | De-registration bricks every exit path (was Medium) | `first-principles` | REFUTED |
| R-05 | *refuted* | Event-only oracle read blocks `addCollateral` (was Medium) | `first-principles` | REFUTED |

### E.2 Yield per agent

| Agent | Confirmed | Low | Info | Leads | Refuted | Mitigated entries | Notes |
|-------|----------:|----:|-----:|------:|--------:|------------------:|-------|
| `first-principles` | 1 (shared) | 3 | 0 | 0 | 3 | 12 | Highest raw output and highest refutation rate — the lens works, but its impact claims needed the most correction. Produced L-05, L-06, L-08. |
| `vector-scan` | 0 | 1 (shared ×2) | 3 | 3 | 0 | 20 | Broadest coverage and the largest mitigated list. Only agent to run live `cast` reads and a fork test to *kill* its own candidate (the Aave zero-LTV grief). |
| `periphery` | 0 | 2 | 1 | 1 | 0 | 18 | Only agent to check every encoded call field-by-field against the vendored ABI. Produced L-02 and the clearest doc defect (I-03). |
| `math-precision` | 0 | 2 | 1 | 0 | 0 | 13 | Produced the only locally-reproduced defect (L-04) and the cross-adapter semantic inconsistency (I-05). |
| `execution-trace` | 0 | 1 (shared) | 1 | 2 | 0 | 13 | Settled the transient-storage question by construction rather than assumption. Produced I-06. |
| `invariants` | 1 | 0 | 0 | 0 | 1 | 8 | Produced the only surviving finding, by checking the code's own claimed invariants against a second gate the claims do not scope. Full invariant catalog with per-invariant coverage assessment. |
| `economic` | 0 | 0 | 1 | 1 | 1 | 4 | Smallest yield; its main candidate was refuted on venue borrow-time checks. Correctly identified the oracle question as out of its scope rather than overreaching. |
| `access-control` | 0 | 0 | 1 (shared) | 0 | 0 | 7 | **Zero findings, by design and correctly.** Traced all six brief questions to line-level conclusions and found no gap beyond the accepted boundaries. A clean access-control result on a contract holding user leverage is a substantive finding in itself. |

### E.3 Coverage gaps across all eight agents

Stated plainly, because these bound the confidence of this report:

1. **No fork tests were executed.** No RPC endpoint was available in the review environment. Claims about live Aave v3/v4 and Comet internal rounding, capping, and liquidation behavior rest on vendored interface NatSpec plus same-block accrual reasoning, and on the assertions pinned in the repo's own fork tests read as evidence. This is the binding constraint on LD-01, LD-02, LD-03, LD-06, and I-03. Two agents did run targeted mainnet fork tests locally (the Aave zero-LTV grief refutation, and the L-04 reproduction against `test/mocks/MockComet.sol`), removing the temporary files afterward.
2. **No Foundry PoC was written for any reported finding.** Under the severity matrix a PoC is mandatory only at High and Critical, and nothing reached either. L-03 and L-04 are the two where a PoC would add most: L-03's test hook already exists and is unwired (`test/mocks/MockLendingAdapter.sol:27`), and L-04 was reproduced ad hoc but not committed.
3. **Aave v3/v4, Compound v3, and Morpho Blue internals were treated as out of scope**, so protocol-side behavior is reasoned from interfaces. v4-core `PoolManager` internals likewise: hook-mediated delta manipulation was reasoned about from the router's side only, and the SETTLEMENT invariant is treated as enforced at that out-of-scope layer.
4. **The 267-function margin test suite was not executed.** Coverage-gap claims in this report are derived from reading the tests, not from a coverage run. Three specific gaps were identified by reading: no test disables an adapter market with a live position and then closes (L-01), `setForcedTarget` is never called (L-03), and no invariant asserts `describePosition(...).currentLtv <= maxLtv` after a handler sequence.

### E.4 Recommended follow-up, in priority order

1. **Fix L-03** (four-line change plus four negative tests using the already-written `setForcedTarget` hook). It makes four existing spec claims true, and it is the single change that most reduces the blast radius of a future bad allowlist entry.
2. **Fix L-04** (one-word change: guard on `debtValue`, not `debt`), plus the construction-time `baseScale` check, which also closes the D.6 price-scale caveat.
3. **Decide on L-01.** Either implement the append-only exit registry, or explicitly scope the exitability comments and publish a per-venue `MarginAccount.execute` recovery recipe. Do not leave the comment as-is.
4. **Fix the event-integrity trio (L-02, L-05, L-08)** together, since all three land on the same indexer contract, and re-examine `src/interfaces/IMarginRouter.sol:66-67` while doing so.
5. **Add the three named regression tests**: disable-then-close (L-01), the forced-target negatives (L-03), and the Aave zero-LTV donation grief as a fork regression test so an Aave upgrade that reintroduces auto-enablement is caught (D.5).
6. **Resolve LD-01 and LD-02 with fork tests** against the live Aave v4 Spoke. Both hinge on the same unverified question — whether the Spoke's amounts and transfers behave exactly as the vendored interface documents — and one fork-test session should settle both plus LD-06.
7. **Commission the oracle review flagged in I-07** for each live market before TVL grows.

---

*Report assembled from eight parallel agent reviews plus an adversarial refutation pass. Every `src/File.sol:Lnn` reference above was re-read from source at commit `e3d86dd2f8199e4265adf0579ba3af953aeb2a0b` during assembly; drift found and corrected is listed in Appendix B.3. No finding was dropped for an unverifiable citation.*
