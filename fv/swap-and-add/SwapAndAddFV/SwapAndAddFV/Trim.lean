import SwapAndAddFV.Assumptions
import SwapAndAddFV.SwapAndAddMath

/-!
# P2: the trim frees enough of the shortfall token

SPEC.md P2a–P2c for `getLiquidityToTrim`.
-/

namespace SwapAndAddFV

/-! ## Rounding facts -/

/-- Ceiling division is an upper bound: `a·b ≤ ⌈a·b/k⌉·k`. -/
theorem mul_le_mulDivUp_mul {a b k : ℕ} (hk : 0 < k) : a * b ≤ mulDivUp a b k * k := by
  unfold mulDivUp
  split_ifs with h
  · rw [Nat.add_zero, Nat.div_mul_cancel (Nat.dvd_of_mod_eq_zero h)]
  · rw [Nat.add_mul, Nat.one_mul]
    exact (Nat.lt_div_mul_add hk).le

/-- Ceiling division is the least such bound: if `a·b ≤ L·k` then `⌈a·b/k⌉ ≤ L`. -/
theorem mulDivUp_le_of_mul_le {a b k L : ℕ} (hk : 0 < k) (h : a * b ≤ L * k) :
    mulDivUp a b k ≤ L := by
  unfold mulDivUp
  have h1 : a * b / k ≤ L := Nat.div_le_of_le_mul (Nat.mul_comm L k ▸ h)
  split_ifs with hr
  · simpa using h1
  · have hne : a * b ≠ L * k := by
      intro heq; apply hr; rw [heq]; simp
    have hlt : a * b / k < L := (Nat.div_lt_iff_lt_mul hk).2 (lt_of_le_of_ne h hne)
    omega

/-! ## Price facts from the pool's well-formedness (A1, A2) -/

section PoolFacts

variable {s : PoolState} {tL tU : ℤ} (hw : WellFormed s tL tU)
include hw

theorem price_le_lower_of_tick_lt (h : s.tick < tL) : s.sqrtPrice ≤ s.sqrtAt tL :=
  hw.slot0_upper.trans (hw.strictMono.monotone (by omega))

theorem price_le_upper_of_tick_lt (h : s.tick < tU) : s.sqrtPrice ≤ s.sqrtAt tU :=
  hw.slot0_upper.trans (hw.strictMono.monotone (by omega))

theorem lower_le_price_of_le_tick (h : tL ≤ s.tick) : s.sqrtAt tL ≤ s.sqrtPrice :=
  (hw.strictMono.monotone h).trans hw.slot0_lower

theorem upper_le_price_of_le_tick (h : tU ≤ s.tick) : s.sqrtAt tU ≤ s.sqrtPrice :=
  (hw.strictMono.monotone h).trans hw.slot0_lower

theorem lower_lt_upper : s.sqrtAt tL < s.sqrtAt tU := hw.strictMono hw.range

end PoolFacts

/-! ## What a removal pays (D4, rounded down) -/

section Removal

variable {s : PoolState} {tL tU : ℤ} (hw : WellFormed s tL tU)
include hw

/-- With the price above `lo`, removing `L` pays `⌊L·(min(p, hi) − lo)/Q⌋` of token1. -/
theorem removal_amount1_eq (hp : s.sqrtAt tL < s.sqrtPrice) (L : ℕ) :
    (positionAmounts s tL tU L false).2 =
      mulDiv L (min s.sqrtPrice (s.sqrtAt tU) - s.sqrtAt tL) Q := by
  have hlu := lower_lt_upper hw
  unfold positionAmounts
  split_ifs with h1 h2
  · exact absurd (price_le_lower_of_tick_lt hw h1) (by omega)
  · have hle := price_le_upper_of_tick_lt hw h2
    simp only [getAmount1Delta, Bool.false_eq_true, ite_false]
    rw [min_eq_left hle, max_eq_right hp.le, min_eq_left hp.le]
  · have hge := upper_le_price_of_le_tick hw (by omega)
    simp only [getAmount1Delta, Bool.false_eq_true, ite_false]
    rw [min_eq_right hge, max_eq_right hlu.le, min_eq_left hlu.le]

/-- With the price at or below `lo`, a removal pays no token1. -/
theorem removal_amount1_zero (hp : s.sqrtPrice ≤ s.sqrtAt tL) (L : ℕ) :
    (positionAmounts s tL tU L false).2 = 0 := by
  have hlu := lower_lt_upper hw
  unfold positionAmounts
  split_ifs with h1 h2
  · rfl
  · have hge := lower_le_price_of_le_tick hw (by omega)
    have heq : s.sqrtPrice = s.sqrtAt tL := le_antisymm hp hge
    simp [getAmount1Delta, mulDiv, heq]
  · exact absurd ((upper_le_price_of_le_tick hw (by omega)).trans hp) (by omega)

/-- With the price below `hi`, removing `L` pays `⌊⌊L·Q·(hi − c)/hi⌋/c⌋` of token0, where
    `c = max(p, lo)`. -/
theorem removal_amount0_eq (hp : s.sqrtPrice < s.sqrtAt tU) (L : ℕ) :
    (positionAmounts s tL tU L false).1 =
      mulDiv (L * Q) (s.sqrtAt tU - max s.sqrtPrice (s.sqrtAt tL)) (s.sqrtAt tU) /
        max s.sqrtPrice (s.sqrtAt tL) := by
  have hlu := lower_lt_upper hw
  unfold positionAmounts
  split_ifs with h1 h2
  · have hle := price_le_lower_of_tick_lt hw h1
    simp only [getAmount0Delta, Bool.false_eq_true, ite_false, max_eq_right hlu.le,
      min_eq_left hlu.le, max_eq_right hle]
  · have hge := lower_le_price_of_le_tick hw (by omega)
    simp only [getAmount0Delta, Bool.false_eq_true, ite_false, max_eq_right hp.le,
      min_eq_left hp.le, max_eq_left hge]
  · exact absurd (upper_le_price_of_le_tick hw (by omega)) (by omega)

/-- With the price at or above `hi`, a removal pays no token0. -/
theorem removal_amount0_zero (hp : s.sqrtAt tU ≤ s.sqrtPrice) (L : ℕ) :
    (positionAmounts s tL tU L false).1 = 0 := by
  have hlu := lower_lt_upper hw
  unfold positionAmounts
  split_ifs with h1 h2
  · exact absurd ((hp.trans (price_le_lower_of_tick_lt hw h1))) (by omega)
  · have heq : s.sqrtPrice = s.sqrtAt tU := le_antisymm (price_le_upper_of_tick_lt hw h2) hp
    simp [getAmount0Delta, mulDiv, heq]
  · rfl

end Removal

/-! ## Token1 shortfall -/

/-- Removing `⌈d·Q/k⌉` liquidity over a token1 width of `k` pays at least `d`. -/
theorem le_mulDiv_mulDivUp {d k : ℕ} (hk : 0 < k) : d ≤ mulDiv (mulDivUp d Q k) k Q := by
  unfold mulDiv
  rw [Nat.le_div_iff_mul_le Q_pos]
  exact mul_le_mulDivUp_mul hk

/-- **P2a (token1).** The trim returns the sentinel exactly when no removal pays any token1. -/
theorem trim_none_iff_token1 {s : PoolState} {tL tU : ℤ} (hw : WellFormed s tL tU) (d : ℕ) :
    getLiquidityToTrim s.sqrtPrice (s.sqrtAt tL) (s.sqrtAt tU) true d = none ↔
      ∀ L, (positionAmounts s tL tU L false).2 = 0 := by
  have hlu := lower_lt_upper hw
  simp only [getLiquidityToTrim, ite_true]
  split_ifs with hp
  · simpa using removal_amount1_zero hw hp
  · simp only [false_iff, not_forall]
    refine ⟨Q, ?_⟩
    rw [removal_amount1_eq hw (by omega), mulDiv, Nat.mul_div_cancel_left _ Q_pos]
    omega

/-- **P2b (token1).** If the trim returns a finite `T`, removing `T` liquidity pays at least `d`
    of token1. -/
theorem trim_covers_token1 {s : PoolState} {tL tU : ℤ} (hw : WellFormed s tL tU) {d T : ℕ}
    (hT : getLiquidityToTrim s.sqrtPrice (s.sqrtAt tL) (s.sqrtAt tU) true d = some T) :
    d ≤ (positionAmounts s tL tU T false).2 := by
  have hlu := lower_lt_upper hw
  simp only [getLiquidityToTrim, ite_true] at hT
  split_ifs at hT with hp
  obtain rfl := Option.some.inj hT
  rw [removal_amount1_eq hw (by omega)]
  exact le_mulDiv_mulDivUp (by omega)

/-- **P2c (token1).** The trim is the least liquidity whose removal pays at least `d` of token1. -/
theorem trim_minimal_token1 {s : PoolState} {tL tU : ℤ} (hw : WellFormed s tL tU) {d T : ℕ}
    (hT : getLiquidityToTrim s.sqrtPrice (s.sqrtAt tL) (s.sqrtAt tU) true d = some T)
    (L : ℕ) (hL : d ≤ (positionAmounts s tL tU L false).2) : T ≤ L := by
  have hlu := lower_lt_upper hw
  simp only [getLiquidityToTrim, ite_true] at hT
  split_ifs at hT with hp
  obtain rfl := Option.some.inj hT
  rw [removal_amount1_eq hw (by omega), mulDiv, Nat.le_div_iff_mul_le Q_pos] at hL
  exact mulDivUp_le_of_mul_le (by omega) hL

/-! ## Token0 shortfall -/

/-- The token0 trim liquidity for an occupied interval `[c, hi]`, as computed by both code paths
    of `getLiquidityToTrim`. -/
def trim0 (c hi d : ℕ) : ℕ :=
  if hi ≤ Q then mulDivUp d (c * hi) ((hi - c) * Q)
  else mulDivUp d (mulDivUp c hi Q) (hi - c)

theorem getLiquidityToTrim_token0 {p lo hi d : ℕ} (hp : p < hi) :
    getLiquidityToTrim p lo hi false d = some (trim0 (max p lo) hi d) := by
  simp only [getLiquidityToTrim, Bool.false_eq_true, ite_false, trim0]
  split_ifs <;> first | omega | rfl

/-- Removing `trim0 c hi d` liquidity over the token0 interval `[c, hi]` pays at least `d`, on
    both code paths. -/
theorem le_amount0_trim0 {c hi d : ℕ} (hc : 0 < c) (hch : c < hi) :
    d ≤ mulDiv (trim0 c hi d * Q) (hi - c) hi / c := by
  unfold mulDiv
  rw [Nat.div_div_eq_div_mul, Nat.le_div_iff_mul_le (Nat.mul_pos (by omega) hc)]
  have hw : 0 < hi - c := by omega
  unfold trim0
  split_ifs with hQ
  · have h := mul_le_mulDivUp_mul (a := d) (b := c * hi) (Nat.mul_pos hw Q_pos)
    calc d * (hi * c) = d * (c * hi) := by ring
      _ ≤ _ := h
      _ = _ := by ring
  · have hI := mul_le_mulDivUp_mul (a := c) (b := hi) Q_pos
    have hT := mul_le_mulDivUp_mul (a := d) (b := mulDivUp c hi Q) hw
    calc d * (hi * c) = d * (c * hi) := by ring
      _ ≤ d * (mulDivUp c hi Q * Q) := Nat.mul_le_mul_left d hI
      _ = d * mulDivUp c hi Q * Q := by ring
      _ ≤ _ * (hi - c) * Q := Nat.mul_le_mul_right Q hT
      _ = _ := by ring

/-- **P2a (token0).** The trim returns the sentinel exactly when no removal pays any token0. -/
theorem trim_none_iff_token0 {s : PoolState} {tL tU : ℤ} (hw : WellFormed s tL tU) (d : ℕ) :
    getLiquidityToTrim s.sqrtPrice (s.sqrtAt tL) (s.sqrtAt tU) false d = none ↔
      ∀ L, (positionAmounts s tL tU L false).1 = 0 := by
  by_cases hp : s.sqrtAt tU ≤ s.sqrtPrice
  · simp only [getLiquidityToTrim, Bool.false_eq_true, ite_false, hp, ite_true, true_iff]
    exact removal_amount0_zero hw hp
  · have hpu : s.sqrtPrice < s.sqrtAt tU := by omega
    rw [getLiquidityToTrim_token0 hpu]
    simp only [reduceCtorEq, false_iff, not_forall]
    -- removing `hi·c` liquidity pays `Q·(hi − c)` token0, which is positive
    set c := max s.sqrtPrice (s.sqrtAt tL)
    have hc : 0 < c := (hw.pos tL).trans_le (le_max_right _ _)
    have hch : c < s.sqrtAt tU := max_lt hpu (lower_lt_upper hw)
    refine ⟨s.sqrtAt tU * c, ?_⟩
    rw [removal_amount0_eq hw hpu, mulDiv, Nat.div_div_eq_div_mul]
    have : s.sqrtAt tU * c * Q * (s.sqrtAt tU - c) =
        (s.sqrtAt tU * c) * (Q * (s.sqrtAt tU - c)) := by ring
    rw [this, Nat.mul_div_cancel_left _ (Nat.mul_pos (by omega) hc)]
    exact (Nat.mul_pos Q_pos (by omega)).ne'

/-- **P2b (token0).** If the trim returns a finite `T`, removing `T` liquidity pays at least `d`
    of token0. -/
theorem trim_covers_token0 {s : PoolState} {tL tU : ℤ} (hw : WellFormed s tL tU) {d T : ℕ}
    (hT : getLiquidityToTrim s.sqrtPrice (s.sqrtAt tL) (s.sqrtAt tU) false d = some T) :
    d ≤ (positionAmounts s tL tU T false).1 := by
  by_cases hp : s.sqrtAt tU ≤ s.sqrtPrice
  · simp [getLiquidityToTrim, hp] at hT
  · have hpu : s.sqrtPrice < s.sqrtAt tU := by omega
    rw [getLiquidityToTrim_token0 hpu] at hT
    obtain rfl := Option.some.inj hT
    rw [removal_amount0_eq hw hpu]
    exact le_amount0_trim0 ((hw.pos tL).trans_le (le_max_right _ _))
      (max_lt hpu (lower_lt_upper hw))

/-- **P2c (token0, `hi ≤ Q`).** On the single-division path the trim is the least liquidity whose
    removal pays at least `d` of token0. -/
theorem trim_minimal_token0 {s : PoolState} {tL tU : ℤ} (hw : WellFormed s tL tU) {d T : ℕ}
    (hQ : s.sqrtAt tU ≤ Q)
    (hT : getLiquidityToTrim s.sqrtPrice (s.sqrtAt tL) (s.sqrtAt tU) false d = some T)
    (L : ℕ) (hL : d ≤ (positionAmounts s tL tU L false).1) : T ≤ L := by
  by_cases hp : s.sqrtAt tU ≤ s.sqrtPrice
  · simp [getLiquidityToTrim, hp] at hT
  · have hpu : s.sqrtPrice < s.sqrtAt tU := by omega
    rw [getLiquidityToTrim_token0 hpu] at hT
    obtain rfl := Option.some.inj hT
    set c := max s.sqrtPrice (s.sqrtAt tL)
    have hc : 0 < c := (hw.pos tL).trans_le (le_max_right _ _)
    have hch : c < s.sqrtAt tU := max_lt hpu (lower_lt_upper hw)
    rw [removal_amount0_eq hw hpu, mulDiv, Nat.div_div_eq_div_mul,
      Nat.le_div_iff_mul_le (Nat.mul_pos (by omega) hc)] at hL
    simp only [trim0, hQ, ite_true]
    apply mulDivUp_le_of_mul_le (Nat.mul_pos (by omega) Q_pos)
    calc d * (c * s.sqrtAt tU) = d * (s.sqrtAt tU * c) := by ring
      _ ≤ L * Q * (s.sqrtAt tU - c) := hL
      _ = L * ((s.sqrtAt tU - c) * Q) := by ring

/-- Ceiling division exceeds the exact quotient by less than one: `⌈a·b/k⌉·k < a·b + k`. -/
theorem mulDivUp_mul_lt {a b k : ℕ} (hk : 0 < k) : mulDivUp a b k * k < a * b + k := by
  unfold mulDivUp
  have h1 := Nat.div_mul_le_self (a * b) k
  split_ifs with h
  · rw [Nat.add_zero]; omega
  · have h2 := Nat.div_add_mod (a * b) k
    have h3 := Nat.mod_lt (a * b) hk
    rw [Nat.add_mul, Nat.one_mul]
    rw [Nat.mul_comm] at h2
    omega

/-- **P2c (token0, `hi > Q`).** On the split path the trim is not always minimal, but it exceeds any
    liquidity whose removal covers the debt by less than `d / (hi − c) + 1`, where
    `c = max(p, lo)`. -/
theorem trim_overshoot_token0 {s : PoolState} {tL tU : ℤ} (hw : WellFormed s tL tU) {d T : ℕ}
    (hT : getLiquidityToTrim s.sqrtPrice (s.sqrtAt tL) (s.sqrtAt tU) false d = some T)
    (L : ℕ) (hL : d ≤ (positionAmounts s tL tU L false).1) :
    (T : ℚ) < L + d / (s.sqrtAt tU - max s.sqrtPrice (s.sqrtAt tL) : ℕ) + 1 := by
  by_cases hp : s.sqrtAt tU ≤ s.sqrtPrice
  · simp [getLiquidityToTrim, hp] at hT
  have hpu : s.sqrtPrice < s.sqrtAt tU := by omega
  rw [getLiquidityToTrim_token0 hpu] at hT
  obtain rfl := Option.some.inj hT
  set hi := s.sqrtAt tU
  set c := max s.sqrtPrice (s.sqrtAt tL)
  have hc : 0 < c := (hw.pos tL).trans_le (le_max_right _ _)
  have hch : c < hi := max_lt hpu (lower_lt_upper hw)
  set w := hi - c
  have hw0 : 0 < w := by omega
  -- the covering condition: d·hi·c ≤ L·Q·w
  rw [removal_amount0_eq hw hpu, mulDiv, Nat.div_div_eq_div_mul,
    Nat.le_div_iff_mul_le (Nat.mul_pos (by omega) hc)] at hL
  change d * (hi * c) ≤ L * Q * w at hL
  -- T·w·Q < (L·w + d + w)·Q on both paths
  have key : trim0 c hi d * w * Q < (L * w + d + w) * Q := by
    unfold trim0
    split_ifs with hQ
    · -- single division: T·(w·Q) < d·c·hi + w·Q ≤ L·Q·w + w·Q
      have h := mulDivUp_mul_lt (a := d) (b := c * hi) (Nat.mul_pos hw0 Q_pos)
      calc mulDivUp d (c * hi) (w * Q) * w * Q = mulDivUp d (c * hi) (w * Q) * (w * Q) := by ring
        _ < d * (c * hi) + w * Q := h
        _ = d * (hi * c) + w * Q := by ring
        _ ≤ L * Q * w + w * Q := by gcongr
        _ ≤ L * Q * w + d * Q + w * Q := by omega
        _ = (L * w + d + w) * Q := by ring
    · -- split: T·w < d·I + w, and I·Q < c·hi + Q
      have hT := mulDivUp_mul_lt (a := d) (b := mulDivUp c hi Q) hw0
      have hI := mulDivUp_mul_lt (a := c) (b := hi) Q_pos
      calc mulDivUp d (mulDivUp c hi Q) w * w * Q < (d * mulDivUp c hi Q + w) * Q :=
            Nat.mul_lt_mul_of_pos_right hT Q_pos
        _ = d * (mulDivUp c hi Q * Q) + w * Q := by ring
        _ ≤ d * (c * hi + Q) + w * Q := by gcongr
        _ = d * (hi * c) + d * Q + w * Q := by ring
        _ ≤ L * Q * w + d * Q + w * Q := by gcongr
        _ = (L * w + d + w) * Q := by ring
  have key' : trim0 c hi d * w < L * w + d + w := Nat.lt_of_mul_lt_mul_right key
  have hwq : (0 : ℚ) < w := by exact_mod_cast hw0
  have hq : ((trim0 c hi d : ℕ) : ℚ) * w < (L * w + d + w : ℕ) := by exact_mod_cast key'
  push_cast at hq
  calc ((trim0 c hi d : ℕ) : ℚ) < (L * w + d + w) / w := (lt_div_iff₀ hwq).2 hq
    _ = L + d / w + 1 := by field_simp

/-! ## P2d: when the trim reverts

`getLiquidityToTrim`'s only revert is `FullMath.mulDivRoundingUp` overflowing: the model returns
`some T` and the Solidity reverts exactly when `T ≥ 2^256` (checked against the code by the trim
vectors). The theorems below give the conditions under which that cannot happen, and an input where
it does. Debts are PoolManager deltas, which are `int128`, so `d < 2^128` in practice.
-/

theorem mulDivUp_le_mulDiv_succ (a b k : ℕ) : mulDivUp a b k ≤ a * b / k + 1 := by
  unfold mulDivUp; split_ifs <;> omega

/-- **P2d (token1).** The token1 trim never reverts for a debt below `2^159`. -/
theorem trim_fits_token1 {p lo hi d T : ℕ} (hd : d < 2 ^ 159)
    (hT : getLiquidityToTrim p lo hi true d = some T) : T < U256 := by
  simp only [getLiquidityToTrim, ↓reduceIte] at hT
  split_ifs at hT with hp
  obtain rfl := Option.some.inj hT
  have hk : 0 < min p hi - lo ∨ min p hi - lo = 0 := by omega
  calc mulDivUp d Q (min p hi - lo) ≤ d * Q / (min p hi - lo) + 1 := mulDivUp_le_mulDiv_succ _ _ _
    _ ≤ d * Q + 1 := by gcongr; exact Nat.div_le_self _ _
    _ < U256 := by unfold U256 Q; omega

/-- **P2d (token0, `hi ≤ Q`).** The single-division token0 trim never reverts for a debt below
    `2^159`. -/
theorem trim_fits_token0_single {p lo hi d T : ℕ} (hlh : lo < hi) (hQ : hi ≤ Q) (hd : d < 2 ^ 159)
    (hT : getLiquidityToTrim p lo hi false d = some T) : T < U256 := by
  by_cases hp : hi ≤ p
  · simp [getLiquidityToTrim, hp] at hT
  have hpu : p < hi := by omega
  rw [getLiquidityToTrim_token0 hpu] at hT
  obtain rfl := Option.some.inj hT
  simp only [trim0, hQ, ↓reduceIte]
  have hch : max p lo < hi := max_lt hpu hlh
  have hwQ : Q ≤ (hi - max p lo) * Q := Nat.le_mul_of_pos_left Q (by omega)
  calc mulDivUp d (max p lo * hi) ((hi - max p lo) * Q)
        ≤ d * (max p lo * hi) / ((hi - max p lo) * Q) + 1 := mulDivUp_le_mulDiv_succ _ _ _
    _ ≤ d * (Q * Q) / Q + 1 := by
        exact Nat.add_le_add_right (Nat.div_le_div (Nat.mul_le_mul_left d
          (Nat.mul_le_mul (hch.le.trans hQ) hQ)) hwQ Q_pos.ne') 1
    _ = d * Q + 1 := by rw [← Nat.mul_assoc, Nat.mul_div_cancel _ Q_pos]
    _ < U256 := by unfold U256 Q; omega

/-- **P2d (token0, `hi > Q`).** The split-path token0 trim never reverts for a debt below `2^128`
    (any `int128` delta) as long as the occupied interval `[max(p, lo), hi]` is at least `2^97`
    sqrt-price units wide. -/
theorem trim_fits_token0_split {p lo hi d T : ℕ} (hhi : hi < 2 ^ 160) (hd : d < 2 ^ 128)
    (hwide : 2 ^ 97 ≤ hi - max p lo)
    (hT : getLiquidityToTrim p lo hi false d = some T) : T < U256 := by
  have hch : max p lo < hi := by omega
  have hpu : p < hi := lt_of_le_of_lt (le_max_left p lo) hch
  rw [getLiquidityToTrim_token0 hpu] at hT
  obtain rfl := Option.some.inj hT
  have hI : mulDivUp (max p lo) hi Q ≤ 2 ^ 224 + 1 :=
    calc mulDivUp (max p lo) hi Q ≤ max p lo * hi / Q + 1 := mulDivUp_le_mulDiv_succ _ _ _
      _ ≤ 2 ^ 160 * 2 ^ 160 / Q + 1 :=
          Nat.add_le_add_right (Nat.div_le_div_right
            (Nat.mul_le_mul (hch.le.trans hhi.le) hhi.le)) 1
      _ = 2 ^ 224 + 1 := by unfold Q; norm_num
  unfold trim0
  split_ifs with hQ
  · -- single-division path: covered by `trim_fits_token0_single`'s argument
    have hwQ : Q ≤ (hi - max p lo) * Q := Nat.le_mul_of_pos_left Q (by omega)
    calc mulDivUp d (max p lo * hi) ((hi - max p lo) * Q)
          ≤ d * (max p lo * hi) / ((hi - max p lo) * Q) + 1 := mulDivUp_le_mulDiv_succ _ _ _
      _ ≤ d * (Q * Q) / Q + 1 := by
          exact Nat.add_le_add_right (Nat.div_le_div (Nat.mul_le_mul_left d
            (Nat.mul_le_mul (hch.le.trans hQ) hQ)) hwQ Q_pos.ne') 1
      _ = d * Q + 1 := by rw [← Nat.mul_assoc, Nat.mul_div_cancel _ Q_pos]
      _ < U256 := by unfold U256 Q; omega
  · calc mulDivUp d (mulDivUp (max p lo) hi Q) (hi - max p lo)
          ≤ d * mulDivUp (max p lo) hi Q / (hi - max p lo) + 1 := mulDivUp_le_mulDiv_succ _ _ _
      _ ≤ 2 ^ 128 * (2 ^ 224 + 1) / 2 ^ 97 + 1 :=
          Nat.add_le_add_right (Nat.div_le_div (Nat.mul_le_mul hd.le hI) hwide (by norm_num)) 1
      _ < U256 := by unfold U256; norm_num

/-- **P2d (a revert).** On the split path the trim can revert: with the price one sqrt-price unit
    below `hi` near the top of the price range, a debt of `2^127` needs more than `2^256` liquidity.
    This is the documented "self-inflicted and atomic" limit in `getLiquidityToTrim`. -/
theorem trim_can_revert :
    ∃ T, getLiquidityToTrim (2 ^ 159 - 1) (2 ^ 158) (2 ^ 159) false (2 ^ 127) = some T ∧
      U256 ≤ T := by
  refine ⟨_, getLiquidityToTrim_token0 (by norm_num), ?_⟩
  unfold trim0 U256 Q mulDivUp
  norm_num

end SwapAndAddFV
