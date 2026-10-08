# SwapAndAdd: Formal Specification

Formal-verification target: `src/libraries/SwapAndAddMath.sol` (phase 1) and `src/SwapAndAdd.sol`
(phase 2).

## Source of truth

The code is the specification. Where this document, the NatSpec, or the
[SwapAndAdd Design](https://app.notion.com/p/uniswaplabs/SwapAndAdd-Design-3c8c52b2548b81368f6bd940b745e06a)
Notion page disagree with the code, the code wins. The Notion page is background only and is not
kept in sync (see [Design doc differences](#design-doc-differences)).

Pinned versions:

| Component  | Revision                                                                                |
| ---------- | --------------------------------------------------------------------------------------- |
| SwapAndAdd | `756be37c` (fix: remove extra +1 unit of burn, #609)                                    |
| v4-core    | `59d3ecf53afa9264a16bba0e38f4c5d2231f80bc` (`lib/v4-core`, as pinned in `foundry.lock`) |

If either changes, every property below must be re-checked against the new code.

## How to read this document

- **Definitions (`D`)** model the v4-core arithmetic that SwapAndAdd depends on. They become Lean
  definitions.
- **Properties (`P`)** are what we prove about `SwapAndAddMath`. Each becomes a Lean theorem.
- **Assumptions (`A`)** are facts we rely on but do not prove. They become hypotheses on the
  theorems. Each one is a statement about something outside the proof (v4-core, the EVM, pool state)
  that a reviewer should agree is true.
- **Contract properties (`C`)** are phase 2, about `SwapAndAdd.sol` as a whole.

Status values: **Proved** (Lean theorem, no `sorry`), **Expected** (paper argument exists, not yet in
Lean), **Conjecture** (believed true, possibly only under extra conditions; may turn out false).

## Notation

- `Q = 2^96` (`FixedPoint96.Q96`).
- `p` is the pool's current sqrt price (`slot0.sqrtPriceX96`), `lo = getSqrtPriceAtTick(tickLower)`,
  `hi = getSqrtPriceAtTick(tickUpper)`. All are `uint160`.
- `L` is liquidity (`uint128` unless stated).
- `⌊x/y⌋` and `⌈x/y⌉` are floor and ceiling division of non-negative integers, `y > 0`.
- All arithmetic in this document is exact (unbounded integers). Overflow and reverts are stated
  separately and explicitly.

## Definitions: v4-core arithmetic

**D1. `mulDiv` / `mulDivRoundingUp`** (`FullMath`). `mulDiv(a, b, d) = ⌊a·b/d⌋` and
`mulDivRoundingUp(a, b, d) = ⌈a·b/d⌉`, computed with a 512-bit intermediate. Reverts if `d = 0` or
the result is `≥ 2^256`. (Assembly; trusted via [A5](#assumptions).)

**D2. Token0 amount** (`SqrtPriceMath.getAmount0Delta(a, b, L, roundUp)`, with `a ≤ b` after
sorting, `a > 0`):

- round down: `⌊ ⌊L·Q·(b − a) / b⌋ / a ⌋`
- round up: `⌈ ⌈L·Q·(b − a) / b⌉ / a ⌉`

**D3. Token1 amount** (`SqrtPriceMath.getAmount1Delta(a, b, L, roundUp)`):

- round down: `⌊L·|b − a| / Q⌋`
- round up: `⌈L·|b − a| / Q⌉`

**D4. Pool position amounts** (`Pool.modifyLiquidity`, liquidity branch). For pool state
`(p, tick)` and range `[tickLower, tickUpper)`:

| Pool state                     | token0          | token1          |
| ------------------------------ | --------------- | --------------- |
| `tick < tickLower`             | `D2(lo, hi, L)` | `0`             |
| `tickLower ≤ tick < tickUpper` | `D2(p, hi, L)`  | `D3(lo, p, L)`  |
| `tick ≥ tickUpper`             | `0`             | `D3(lo, hi, L)` |

Adding liquidity (mint, increase) charges these amounts **rounded up**. Removing liquidity (decrease,
burn) pays these amounts **rounded down**. Fees accrued on the position are paid on top of a removal.

**D5. Combined swap fee** (`ProtocolFeeLibrary.calculateSwapFee(s, l)`), with `s` the one-direction
protocol fee (12 bits) and `l` the LP fee, in pips (`10^6 = 100%`):
`fee = s + l − ⌊s·l / 10^6⌋`.

**D6. Tick to sqrt price** (`TickMath.getSqrtPriceAtTick(tick)`): reverts when `|tick| > 887272`.
Otherwise it multiplies Q128.128 factors `1/sqrt(1.0001^(2^i))` for each set bit `i` of `|tick|`
(flooring after each product), inverts for positive ticks (`⌊(2^256 − 1) / price⌋`), and rounds up
to Q64.96 (`⌈price / 2^32⌉`). Modeled operation by operation in `SwapAndAddFV/TickMath.lean`; the
model reproduces `MIN_SQRT_PRICE`, `MAX_SQRT_PRICE`, tick 0 `= Q` and tick 1 as kernel-checked
theorems (`TickMathFacts.lean`), and is checked against the code by the `ticks.json` vectors.

## Assumptions

**A1. Slot0 consistency.** `getSqrtPriceAtTick(tick) ≤ p ≤ getSqrtPriceAtTick(tick + 1)`. (The upper
equality occurs after a `zeroForOne` swap that ends exactly on a tick boundary, where v4 sets
`tick = boundary − 1`.)

**A2. Tick-to-price is strictly increasing**, and `tickLower < tickUpper`, so `0 < lo < hi`.
Checked exhaustively on the D6 model: all 1,774,545 valid ticks give strictly increasing prices. This
is a computation run by a compiled program, not a kernel-checked proof.

**A3. LP fee bound.** `slot0.lpFee ≤ 10^6` (`LPFeeLibrary.MAX_LP_FEE`), and the stored protocol fee
fits in 12 bits per direction.

**A4. Price is stable within a step.** The pool price read by `_trim` is the price at which the
following decrease executes, and the price read by `_planLiquidity` is the price at which the deploy
executes. A hook that swaps inside `beforeRemoveLiquidity` or `beforeAddLiquidity` breaks this. (The
deploy side fails safe: POSM's amount caps revert. The trim side does not have that protection.)

**A5. `FullMath` is correct.** `mulDiv` and `mulDivRoundingUp` compute exactly D1, and revert exactly
when D1 says. These are assembly; checked against the model with test vectors, not proved.

**A6. Removal pays at least principal.** A decrease returns the D4 rounded-down principal plus
non-negative accrued fees.

## Phase 1: SwapAndAddMath properties

### P1. Mint amounts match the pool exactly

**Code:** `getAmountsForLiquidityRoundingUp(p, lo, hi, L)`.

Under A1 and A2, for every `L`, the returned `(amount0, amount1)` equals the D4 **rounded-up** charge
for adding `L` at pool state `(p, tick)`.

Why it matters: the planned amounts are passed to POSM as the exact caps, and the flash-take is sized
from them. If they were ever a wei below the pool's charge, every such deploy would revert.

Note: SwapAndAddMath branches on the price (`p ≤ lo`, `p < hi`) while the pool branches on the tick.
The two agree at the boundaries `p = lo` and `p = hi` because D2 and D3 return `0` over an empty
interval. This is the main thing the proof checks.

Also: both amounts are non-decreasing in `L`.

**Status:** **Proved**: `roundingUp_eq_pool` (exact match, never reverts on a well-formed pool) and
`roundingUp_mono` (non-decreasing in `L`), in `SwapAndAddFV/SwapAndAddFV/Sizing.lean`.

### P2. Trim frees enough of the shortfall token

**Code:** `getLiquidityToTrim(p, lo, hi, deficitIsCurrency1, d)`, result `T`.

**P2a. Infinite exactly when nothing can be freed.** `T = type(uint256).max` if and only if the
position holds none of the shortfall token at price `p`: `p ≤ lo` for a token1 shortfall, `p ≥ hi`
for a token0 shortfall.

**P2b. Sufficiency.** Under A1, A2, A4 and A6, if `T` is finite and `T < 2^128`, removing `T`
liquidity at price `p` pays at least `d` of the shortfall token.

- Token1 shortfall: with `c = min(p, hi)`, `T = ⌈d·Q / (c − lo)⌉`, and the removal pays
  `⌊T·(c − lo) / Q⌋ ≥ d`.
- Token0 shortfall: with `c = max(p, lo)`, the removal pays `⌊T·Q·(hi − c) / (c·hi)⌋` (D2 rounded
  down, using `⌊⌊x/m⌋/n⌋ = ⌊x/(m·n)⌋`), which is `≥ d` on both code paths:
  - `hi ≤ Q`: `T = ⌈d·c·hi / ((hi − c)·Q)⌉`.
  - `hi > Q`: `T = ⌈d·I / (hi − c)⌉` with `I = ⌈c·hi / Q⌉`.

This is the property #609 depends on. Before #609 the code used `d + 1`; the comment now states that
a rounded-down removal covers an integer debt whenever its unrounded output is at least that debt.

**P2c. Tightness.** For a token1 shortfall and for a token0 shortfall with `hi ≤ Q`, `T` is the
**smallest** liquidity whose removal pays at least `d`. For a token0 shortfall with `hi > Q`, `T`
exceeds any liquidity whose removal pays at least `d` by less than `d / (hi − c) + 1`.

**P2d. Reverts.** The only revert is `mulDivRoundingUp` overflowing (`T ≥ 2^256`); the vectors check
the model's `T ≥ 2^256` matches the code's reverts exactly. Debts are `int128` PoolManager deltas, so
`d < 2^128` in practice. Then:

- the token1 trim never reverts (any `d < 2^159`);
- the token0 trim with `hi ≤ Q` never reverts (any `d < 2^159`);
- the token0 trim with `hi > Q` never reverts when the occupied interval `[max(p, lo), hi]` is at
  least `2^97` sqrt-price units wide;
- it can revert otherwise: with `p = 2^159 − 1`, `lo = 2^158`, `hi = 2^159` and `d = 2^127`, the
  required liquidity exceeds `2^256`. This is the limit the code documents as "self-inflicted and
  atomic".

**Status:**

- P2a **Proved**: `trim_none_iff_token1`, `trim_none_iff_token0`.
- P2b **Proved**: `trim_covers_token1`, `trim_covers_token0` (both code paths).
- P2c **Proved**: `trim_minimal_token1`, `trim_minimal_token0` (`hi ≤ Q`, exact minimum), and
  `trim_overshoot_token0` (`hi > Q`, the bound).
- P2d **Proved**: `trim_fits_token1`, `trim_fits_token0_single`, `trim_fits_token0_split`, and
  `trim_can_revert` (the reverting input).

All in `SwapAndAddFV/SwapAndAddFV/Trim.lean`. The model of `getLiquidityToTrim` and of D2/D3 is
checked against the Solidity by `test/SwapAndAddMathLeanModel.t.sol` (see the README).

### P3. Fee arithmetic cannot underflow

**Code:** `getLiquidityFeeAware`, the expression `PIPS_DENOMINATOR − feePips`.

Under A3, `calculateSwapFee(s, l) ≤ 10^6`, so the subtraction never underflows. Equality holds when
`l = 10^6`. In that case the surplus token is weighted at zero.

**Status:** **Proved**: `calculateSwapFee_le`, `calculateSwapFee_full` (equality at a 100% LP fee),
and `feeWeight_no_underflow` (the subtraction as it appears in the code), in `Sizing.lean`.

### P4. Fee-aware sizing

**Code:** `getLiquidityFeeAware`.

**P4a. Zero fee changes nothing.** If the surplus-side combined fee is `0`, the result equals the
mid-price sizing (`midLiquidity`). (Both calls are identical.)

**P4b. The discount never increases liquidity.** The result is `≤ midLiquidity`.

In exact arithmetic this holds because lowering the weight on the side whose budget-to-reference
ratio is larger can only lower the weighted ratio. With the code's rounding it may be off by a small
amount; part of the work is finding the exact bound.

**Status:**

- P4a **Proved** as `feeAware_zero_fee` in `Sizing.lean`, for zero fee in both directions and positive
  range bounds.
- P4b **False as stated; holds only up to rounding.** Open; parked on 2026-10-07.

P4b findings (model only, 300,000 random samples, 172,161 of which sized without reverting):

- 38 samples had fee-aware sizing above `midLiquidity`.
- With range widths of at least `2^88` sqrt-price units, the excess was at most `2^7` units on
  liquidity around `2^126`: rounding noise.
- The large excesses (about 0.01% to 1% of liquidity) all had range widths of `2^2` to `2^19`
  sqrt-price units. Real ranges are tick-aligned, and one tick near price 1 is about `2^82` units
  wide, so these inputs cannot occur on a pool. The vector and search generators pick range bounds as
  arbitrary integers, which is why they appear.
- Over-sizing is a quality issue, not a safety one: the reconcile trim and `minLiquidity` bound the
  outcome.

Tick-aligned follow-up (2026-10-08, ranges built with the D6 model, all common spacings): 22 of
319,488 sized samples exceeded `midLiquidity`. 21 by 1 to 36,652 units (at most 0.05% relative, the
largest relative values all with budgets of a few wei); 1 by about `2^92` units on liquidity of about
`2^124` (relative error about `2^-32`). The excess tracks the floor error in valuing the budgets, so
it is worth about a wei or two of budget value rather than a fixed number of liquidity units.

Plan when resuming: restate P4b as "fee-aware sizing is at most mid-price sizing plus the liquidity
worth a couple of wei of budget value", and prove it from the exact-arithmetic argument plus floor
error bounds.

### P5. Cheaper-token numeraire

**Code:** `getLiquidityForAmountsWeighted`.

**P5a.** `rateX96 ≥ Q` on both branches (`p ≥ Q` and `p < Q`).

**P5b.** `rateX96 · pipsWeight` (a plain checked multiplication inside `_tokenValue`, which would
revert on overflow) never overflows: for any valid price (`2^32 ≤ p < 2^160`; `MIN_SQRT_PRICE > 2^32`)
`rateX96` is computed without reverting and is `≤ 2^224`, and `pipsWeight ≤ 10^6`.

**P5c.** The reference half of the computation never reverts on valid inputs: for
`2^32 ≤ lo < hi < 2^160`, `2^32 ≤ p < 2^160` and weights of at most `10^6`, the rate, both
reference amounts (at `REFERENCE_LIQUIDITY = 2^128 − 1`), and both token values are computed, and
`refValue < 2^194`.

**P5d. Reverts.** On the inputs of P5c, the reference half is a fixed computation that cannot
revert, so the function reduces to its budget half: value the budgets, then scale by
`REFERENCE_LIQUIDITY / refValue`. Its only reverts are a budget token value or the sum of the two
overflowing, or the result not fitting in `uint128`. In particular it never reverts when each budget
is at most the matching reference amount (what a `type(uint128).max` position needs at this price),
and then the result is at most `REFERENCE_LIQUIDITY`.

**Status:** P5a **Proved** (`Q_le_rateX96`). P5b **Proved** (`rateX96_le`, `rate_mul_weight_fits`).
P5c **Proved** (`referenceValue_fits`). P5d **Proved** (`weighted_eq_budget_side`,
`weighted_fits_of_le_reference`). All in `Sizing.lean`.

### P6. Planned amounts are short on at most one side

**Code:** `SwapAndAdd._planLiquidity` (sizing plus the one-unit step-down). Included in phase 1
because it is pure arithmetic over `SwapAndAddMath`.

After the step-down, at most one of `amount0 > budget0`, `amount1 > budget1` holds.

Why it matters: `_reconcile` handles exactly one shortfall token. If both were short, it is not yet
known whether the operation reverts at the end of the unlock or settles anyway (the trim frees both
tokens when in range). Either way it is a liveness question, not a loss of funds.

**Status: False as stated.** Open; parked on 2026-10-07, to resume later.

Findings so far (model only, not yet reproduced in Solidity):

- The model reproduces the pinned OZ N-08 case (`test/SwapAndAddMath.t.sol`,
  `test_getLiquidityFeeAware_canOvershootBothBudgets`): sizing overshoots both budgets by one wei at
  `L ≈ 2^95`, and the step-down fixes it.
- Counterexample at `L ≈ 2^127`: one-tick range `lo = Q`, `hi = getSqrtPriceAtTick(1) =
79232123823359799118286999568`, `p = 79229978236368137126535968673`, budgets
  `(5339445463856191365274488148172919, 4518882767367605356398569133400885)` (the rounded-up amounts
  for `L = 197179280643618327718831751682240685823`), protocol fee `0`, LP fee `100`. Sizing returns
  `197179280643618327718831751682240702186`, about 16,000 units too many; after the one-unit step-down
  both amounts are still one wei over budget.
- No failure found for `2^90 ≤ L < 2^123` in 2,000,000 samples near-peg and across range widths.
- v4 caps liquidity per tick (`Pool.tickSpacingToMaxLiquidityPerTick`): about `2^107` at tick
  spacing 1 and about `2^122` at the largest spacing. So the counterexample above cannot be minted.

Tick-aligned follow-up (2026-10-08, ranges built with the D6 model, liquidity capped at each
spacing's `maxLiquidityPerTick`): 2,000,000 samples across spacings and 3,000,000 one-tick samples at
spacing 1 (the N-08 shape, liquidity up to `2^107`), with budgets equal to a mintable position's
amounts. The step-down never triggered, and no sample stayed short on both tokens. A rough error
analysis agrees: a one-unit two-sided overshoot comes from rounding the amounts up (the N-08 case,
fixed by the step-down); needing more than one unit requires the floor error in the reference value
to be worth a whole liquidity unit, which at price 1 happens only above about 45 times the per-tick
cap. This is evidence, not a proof.

Plan when resuming:

1. Bound the sizing overshoot as a function of `L`, to find the threshold below which one unit of
   step-down always suffices.
2. Compare the threshold with the per-tick liquidity cap. If the threshold is higher, restate P6 with
   `L` below the cap as a precondition and prove it.
3. If the threshold is lower, there is a reachable case: reproduce it end to end in Solidity, find
   out whether `add` reverts or settles through the trim, and raise it with the team.

### P7. Trim cap and cast

**Code:** `SwapAndAdd._trim`, `dl = liquidityToTrim >= lopt ? lopt : uint128(liquidityToTrim)`.

`dl ≤ lopt`, so the trim never removes liquidity that existed before this transaction. The `uint128`
cast only runs when `liquidityToTrim < lopt < 2^128`, so it never truncates.

**Status:** **Proved**: `trimCap_le`, `trimCap_cast_exact` in `Sizing.lean`. The cap is modeled as
`trimCap` in `SwapAndAddMath.lean` (checked against the code by inspection; it is one line of
`_trim`).

## Phase 2: Contract properties (not started)

Listed so phase 1 work stays aligned with them. Each will be refined into precise statements later.
The "Method" column is a first guess.

| ID  | Property                                                                                                                                    | Method           |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------- | ---------------- |
| C1  | Funds pulled, collected, and declared as route funding are deployed or swept to the recipient in the same transaction (donations excepted). | Lean state model |
| C2  | The final liquidity is `≥ minLiquidity`, or the call reverts.                                                                               | Halmos           |
| C3  | `increase` and `compound` never reduce the liquidity that existed before the call (follows from P7).                                        | Lean state model |
| C4  | Pools whose hook has any returns-delta permission are rejected.                                                                             | Halmos           |
| C5  | When an operator calls `rebalance`, `increase`, or `compound`, all output goes to the position owner.                                       | Halmos           |
| C6  | The pool price at sizing is inside `[sqrtPriceMinX96, sqrtPriceMaxX96]`, or the call reverts.                                               | Halmos           |
| C7  | `msg.value` has a single meaning per operation, and a multicall cannot spend the same ETH twice.                                            | Halmos           |
| C8  | The deploy and the trim (for swap-hook pools) revert if POSM is in debt to the PoolManager.                                                 | Halmos           |
| C9  | The flash-take debt is fully settled when the unlock ends, or the call reverts.                                                             | Lean state model |

## Out of scope

- The Universal Router route (a black box by design).
- Permit2, POSM, and PoolManager internals beyond the arithmetic in D1–D5.
- Gas.

## Design doc differences

The code wins in each case. Listed so readers of the Notion page know where it no longer applies.

| Notion claim                                                                                          | Code                                                                                                                        |
| ----------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| §4: the trim is a ceiling inverse over `debt + 1`.                                                    | Over `debt` exactly since #609. See P2b.                                                                                    |
| §4: "Integer division truncates towards zero in the safe direction, slightly under-sizing liquidity." | Rounding can over-size, leaving both amounts a wei over budget. `_planLiquidity` steps down one unit to handle it (see P6). |
