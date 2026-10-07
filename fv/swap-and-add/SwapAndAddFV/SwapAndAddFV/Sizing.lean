import SwapAndAddFV.Assumptions
import SwapAndAddFV.Trim

/-!
# Sizing and fee properties

SPEC.md P1 (mint amounts match the pool), P3 (fee arithmetic cannot underflow), P5a/P5b (the
cheaper-token rate), and P7 (the trim cap).
-/

namespace SwapAndAddFV

/-! ## P1: mint amounts match the pool exactly -/

theorem getAmount0Delta_self (a L : ℕ) (roundUp : Bool) : getAmount0Delta a a L roundUp = 0 := by
  cases roundUp <;> simp [getAmount0Delta, mulDiv, mulDivUp, divUp]

theorem getAmount1Delta_self (a L : ℕ) (roundUp : Bool) : getAmount1Delta a a L roundUp = 0 := by
  cases roundUp <;> simp [getAmount1Delta, mulDiv, mulDivUp]

/-- **P1.** `getAmountsForLiquidityRoundingUp` never reverts on a well-formed pool and returns
    exactly what the pool charges to add `L` liquidity (D4, rounded up). SwapAndAddMath branches on
    the price while the pool branches on the tick; they agree, including when the price is exactly
    on a range bound. -/
theorem roundingUp_eq_pool {s : PoolState} {tL tU : ℤ} (hw : WellFormed s tL tU) (L : ℕ) :
    getAmountsForLiquidityRoundingUp s.sqrtPrice (s.sqrtAt tL) (s.sqrtAt tU) L =
      some (positionAmounts s tL tU L true) := by
  have hlu := lower_lt_upper hw
  have hlo := hw.pos tL
  unfold getAmountsForLiquidityRoundingUp positionAmounts
  by_cases hp1 : s.sqrtPrice ≤ s.sqrtAt tL
  · -- at or below the range: token0 only, over [lo, hi]
    have hmin : ¬ min (s.sqrtAt tL) (s.sqrtAt tU) = 0 := by rw [min_eq_left hlu.le]; omega
    simp only [hp1, hmin, ↓reduceIte]
    by_cases ht1 : s.tick < tL
    · simp only [ht1, ↓reduceIte]
    · have heq : s.sqrtPrice = s.sqrtAt tL :=
        le_antisymm hp1 (lower_le_price_of_le_tick hw (by omega))
      have ht2 : s.tick < tU := by
        by_contra h
        exact absurd ((upper_le_price_of_le_tick hw (by omega)).trans hp1) (by omega)
      simp only [ht1, ht2, ↓reduceIte, heq, getAmount1Delta_self]
  · have ht1 : ¬ s.tick < tL := fun h => hp1 (price_le_lower_of_tick_lt hw h)
    by_cases hp2 : s.sqrtPrice < s.sqrtAt tU
    · -- strictly inside the range: both tokens
      have hmin : ¬ min s.sqrtPrice (s.sqrtAt tU) = 0 := by rw [min_eq_left hp2.le]; omega
      have ht2 : s.tick < tU := by
        by_contra h
        exact absurd (upper_le_price_of_le_tick hw (by omega)) (by omega)
      simp only [hp1, hp2, hmin, ht1, ht2, ↓reduceIte]
    · -- at or above the range: token1 only, over [lo, hi]
      simp only [hp1, hp2, ht1, ↓reduceIte]
      by_cases ht2 : s.tick < tU
      · have heq : s.sqrtPrice = s.sqrtAt tU :=
          le_antisymm (price_le_upper_of_tick_lt hw ht2) (by omega)
        simp only [ht2, ↓reduceIte, heq, getAmount0Delta_self]
      · simp only [ht2, ↓reduceIte]

/-- Ceiling division is monotone in its first factor. -/
theorem mulDivUp_mono {a a' b k : ℕ} (hk : 0 < k) (h : a ≤ a') :
    mulDivUp a b k ≤ mulDivUp a' b k :=
  mulDivUp_le_of_mul_le hk ((Nat.mul_le_mul_right b h).trans (mul_le_mulDivUp_mul hk))

theorem divUp_eq_mulDivUp (x y : ℕ) : divUp x y = mulDivUp x 1 y := by
  simp [divUp, mulDivUp]

/-- **P1 (monotone).** The rounded-up amounts are non-decreasing in liquidity. -/
theorem roundingUp_mono {s : PoolState} {tL tU : ℤ} (hw : WellFormed s tL tU) {L L' : ℕ}
    (h : L ≤ L') :
    (positionAmounts s tL tU L true).1 ≤ (positionAmounts s tL tU L' true).1 ∧
      (positionAmounts s tL tU L true).2 ≤ (positionAmounts s tL tU L' true).2 := by
  have h0 : ∀ a b : ℕ, 0 < min a b → getAmount0Delta a b L true ≤ getAmount0Delta a b L' true := by
    intro a b hab
    have hb : 0 < max a b := lt_of_lt_of_le hab (min_le_max)
    simp only [getAmount0Delta, ↓reduceIte, divUp_eq_mulDivUp]
    exact mulDivUp_mono hab (mulDivUp_mono hb (Nat.mul_le_mul_right Q h))
  have h1 : ∀ a b : ℕ, getAmount1Delta a b L true ≤ getAmount1Delta a b L' true := by
    intro a b
    simp only [getAmount1Delta, ↓reduceIte]
    exact mulDivUp_mono Q_pos h
  have hlu := lower_lt_upper hw
  have hlo := hw.pos tL
  unfold positionAmounts
  split_ifs with h1' h2'
  · exact ⟨h0 _ _ (by rw [min_eq_left hlu.le]; omega), le_rfl⟩
  · have hge := lower_le_price_of_le_tick hw (by omega)
    by_cases hpu : s.sqrtPrice ≤ s.sqrtAt tU
    · exact ⟨h0 _ _ (by rw [min_eq_left hpu]; omega), h1 _ _⟩
    · exact ⟨h0 _ _ (by rw [min_eq_right (by omega)]; omega), h1 _ _⟩
  · exact ⟨le_rfl, h1 _ _⟩

/-! ## P3: fee arithmetic cannot underflow -/

/-- **P3.** With an LP fee of at most `10^6` (A3), the combined swap fee is at most `10^6`, whatever
    the protocol fee. -/
theorem calculateSwapFee_le (pf lf : ℕ) (hlf : lf ≤ PIPS) : calculateSwapFee pf lf ≤ PIPS := by
  have hP : PIPS = 1000000 := rfl
  unfold calculateSwapFee
  have hs : pf % 4096 < 4096 := Nat.mod_lt _ (by norm_num)
  have hl : lf % 2 ^ 24 = lf := Nat.mod_eq_of_lt (by omega)
  simp only [hl]
  set s := pf % 4096
  have key : (s + lf - PIPS) * PIPS ≤ s * lf := by
    rcases le_or_gt (s + lf) PIPS with h | h
    · simp [Nat.sub_eq_zero_of_le h]
    · have h1 : (s : ℤ) ≤ PIPS := by rw [hP]; push_cast; omega
      have h2 : (lf : ℤ) ≤ PIPS := by exact_mod_cast hlf
      zify [h.le]
      nlinarith [mul_nonneg (sub_nonneg.2 h1) (sub_nonneg.2 h2)]
  have : s + lf - PIPS ≤ s * lf / PIPS := (Nat.le_div_iff_mul_le (by rw [hP]; norm_num)).2 key
  omega

/-- At a 100% LP fee the combined fee is exactly 100%, so the surplus token is weighted at zero. -/
theorem calculateSwapFee_full (pf : ℕ) : calculateSwapFee pf PIPS = PIPS := by
  have hP : PIPS = 1000000 := rfl
  simp only [calculateSwapFee, hP]
  rw [show (1000000 : ℕ) % 2 ^ 24 = 1000000 by norm_num,
    Nat.mul_div_cancel _ (by norm_num : 0 < 1000000)]
  omega

/-- **P3, in the code.** The `PIPS_DENOMINATOR - feePips` subtraction in `getLiquidityFeeAware`
    never underflows. -/
theorem feeWeight_no_underflow (pf lf : ℕ) (hlf : lf ≤ PIPS) :
    subC PIPS (calculateSwapFee pf lf) = some (PIPS - calculateSwapFee pf lf) := by
  simp [subC, calculateSwapFee_le pf lf hlf]

/-! ## P5: the cheaper-token rate -/

theorem mulDivC_eq_some {a b d r : ℕ} (h : mulDivC a b d = some r) : 0 < d ∧ r = a * b / d := by
  unfold mulDivC chk mulDiv at h
  split_ifs at h with h1 h2
  exact ⟨Nat.pos_of_ne_zero h1, (Option.some.inj h).symm⟩

/-- **P5a.** Whenever the rate is computed, it is at least `Q`, so valuing in the cheaper token
    multiplies amounts up rather than truncating them toward zero. -/
theorem Q_le_rateX96 {p r : ℕ} (h : rateX96 p = some r) : Q ≤ r := by
  unfold rateX96 at h
  split_ifs at h with hp
  · obtain ⟨-, rfl⟩ := mulDivC_eq_some h
    calc Q = Q * Q / Q := (Nat.mul_div_cancel _ Q_pos).symm
      _ ≤ p * p / Q := Nat.div_le_div_right (Nat.mul_le_mul hp hp)
  · obtain ⟨x, hx, hr⟩ := Option.bind_eq_some_iff.1 h
    obtain ⟨hp0, rfl⟩ := mulDivC_eq_some hx
    obtain ⟨-, rfl⟩ := mulDivC_eq_some hr
    have hxQ : Q ≤ Q * Q / p :=
      calc Q = Q * Q / Q := (Nat.mul_div_cancel _ Q_pos).symm
        _ ≤ Q * Q / p := Nat.div_le_div_left (by omega) hp0
    calc Q ≤ Q * Q / p := hxQ
      _ = Q * Q / p * Q / Q := (Nat.mul_div_cancel _ Q_pos).symm
      _ ≤ Q * Q / p * Q / p := Nat.div_le_div_left (by omega) hp0

theorem mulDivC_of_le {a b d r : ℕ} (hd : 0 < d) (h : a * b / d ≤ r) (hr : r < U256) :
    mulDivC a b d = some (a * b / d) := by
  have : a * b / d < U256 := lt_of_le_of_lt h hr
  simp [mulDivC, chk, mulDiv, hd.ne', this]

/-- **P5b.** For any valid sqrt price (`2^32 ≤ p < 2^160`; `TickMath.MIN_SQRT_PRICE > 2^32`), the
    rate is computed without reverting and is at most `2^224`. -/
theorem rateX96_le {p : ℕ} (hlo : 2 ^ 32 ≤ p) (hhi : p < 2 ^ 160) :
    ∃ r, rateX96 p = some r ∧ r ≤ 2 ^ 224 := by
  have hQ : Q = 2 ^ 96 := rfl
  have hU : (2 : ℕ) ^ 224 < U256 := by unfold U256; norm_num
  have hp0 : 0 < p := lt_of_lt_of_le (by norm_num) hlo
  unfold rateX96
  split_ifs with hp
  · have hb : p * p / Q ≤ 2 ^ 224 := by
      apply Nat.div_le_of_le_mul
      calc p * p ≤ 2 ^ 160 * 2 ^ 160 := Nat.mul_le_mul hhi.le hhi.le
        _ = Q * 2 ^ 224 := by rw [hQ]; norm_num
    exact ⟨_, mulDivC_of_le Q_pos hb hU, hb⟩
  · have hx : Q * Q / p ≤ 2 ^ 160 :=
      calc Q * Q / p ≤ Q * Q / 2 ^ 32 := Nat.div_le_div_left hlo (by norm_num)
        _ = 2 ^ 160 := by rw [hQ]; norm_num
    have hr : Q * Q / p * Q / p ≤ 2 ^ 224 :=
      calc Q * Q / p * Q / p ≤ Q * Q / p * Q / 2 ^ 32 := Nat.div_le_div_left hlo (by norm_num)
        _ ≤ 2 ^ 160 * Q / 2 ^ 32 := Nat.div_le_div_right (Nat.mul_le_mul_right Q hx)
        _ = 2 ^ 224 := by rw [hQ]; norm_num
    refine ⟨_, ?_, hr⟩
    rw [mulDivC_of_le hp0 hx (lt_of_le_of_lt (by norm_num) hU)]
    exact mulDivC_of_le hp0 hr hU

/-- **P5b, in the code.** The `rateX96 * pipsWeight` multiplication in `_tokenValue` never
    overflows for a rate from `rateX96_le` and a weight of at most `10^6`. -/
theorem rate_mul_weight_fits {r w : ℕ} (hr : r ≤ 2 ^ 224) (hw : w ≤ PIPS) :
    chk (r * w) = some (r * w) := by
  have : r * w < U256 :=
    calc r * w ≤ 2 ^ 224 * PIPS := Nat.mul_le_mul hr hw
      _ < U256 := by unfold U256 PIPS; norm_num
  simp [chk, this]

/-! ## P5c: the reference position's value cannot overflow -/

theorem mulDivUp_le_add_one (a b k : ℕ) : mulDivUp a b k ≤ a * b / k + 1 := by
  unfold mulDivUp; split_ifs <;> omega

theorem divUp_le_add_one (x y : ℕ) : divUp x y ≤ x / y + 1 := by
  unfold divUp; split_ifs <;> omega

/-- Rounded-up token0 for `L` over `[c, d]` is at most `L·Q/c + 1`. -/
theorem amount0Up_le {c d L : ℕ} (hc : 0 < c) (hcd : c ≤ d) :
    getAmount0Delta c d L true ≤ L * Q / c + 1 := by
  simp only [getAmount0Delta, ↓reduceIte, min_eq_left hcd, max_eq_right hcd]
  have hd : 0 < d := lt_of_lt_of_le hc hcd
  have hX : mulDivUp (L * Q) (d - c) d ≤ L * Q :=
    mulDivUp_le_of_mul_le hd (Nat.mul_le_mul_left _ (Nat.sub_le d c))
  calc divUp (mulDivUp (L * Q) (d - c) d) c ≤ mulDivUp (L * Q) (d - c) d / c + 1 :=
        divUp_le_add_one _ _
    _ ≤ L * Q / c + 1 := by gcongr

/-- Rounded-up token1 for `L` over `[a, b]` is at most `L·b/Q + 1`. -/
theorem amount1Up_le {a b L : ℕ} (hab : a ≤ b) : getAmount1Delta a b L true ≤ L * b / Q + 1 := by
  simp only [getAmount1Delta, ↓reduceIte, min_eq_left hab, max_eq_right hab]
  calc mulDivUp L (b - a) Q ≤ L * (b - a) / Q + 1 := mulDivUp_le_add_one _ _ _
    _ ≤ L * b / Q + 1 := by gcongr; exact Nat.sub_le b a

/-- A converted token value: computed without reverting, and at most `a·r/Q`. -/
theorem tokenValue_convert {a w r : ℕ} (hw : w ≤ PIPS) (hrw : r * w < U256)
    (hfit : a * r / Q < U256) :
    ∃ v, tokenValue a w r true = some v ∧ v ≤ a * r / Q := by
  have hQP : 0 < Q * PIPS := Nat.mul_pos Q_pos (by unfold PIPS; norm_num)
  have hle : a * (r * w) / (Q * PIPS) ≤ a * r / Q :=
    calc a * (r * w) / (Q * PIPS) ≤ a * r * PIPS / (Q * PIPS) := by
          apply Nat.div_le_div_right
          rw [← Nat.mul_assoc]
          exact Nat.mul_le_mul_left _ hw
      _ = a * r / Q := Nat.mul_div_mul_right _ _ (by unfold PIPS; norm_num)
  refine ⟨_, ?_, hle⟩
  simp only [tokenValue, ↓reduceIte, chk, hrw]
  simp [mulDivC, chk, mulDiv, hQP.ne', lt_of_le_of_lt hle hfit]

/-- An unconverted token value: computed without reverting, and at most the amount. -/
theorem tokenValue_plain {a w r : ℕ} (hw : w ≤ PIPS) (ha : a < U256) :
    ∃ v, tokenValue a w r false = some v ∧ v ≤ a := by
  have hP : 0 < PIPS := by unfold PIPS; norm_num
  have hle : a * w / PIPS ≤ a :=
    Nat.div_le_of_le_mul (Nat.mul_comm PIPS a ▸ Nat.mul_le_mul_left a hw)
  refine ⟨_, ?_, hle⟩
  simp [tokenValue, mulDivC, chk, mulDiv, hP.ne', lt_of_le_of_lt hle ha]

theorem rateX96_eq_of_ge {p : ℕ} (hp : Q ≤ p) (hhi : p < 2 ^ 160) :
    rateX96 p = some (p * p / Q) := by
  obtain ⟨r, hr, -⟩ := rateX96_le (le_trans (by unfold Q; norm_num) hp) hhi
  unfold rateX96 at hr ⊢
  simp only [hp, ↓reduceIte] at hr ⊢
  rw [hr, (mulDivC_eq_some hr).2]

theorem rateX96_eq_of_lt {p : ℕ} (hp : p < Q) (hlo : 2 ^ 32 ≤ p) :
    rateX96 p = some (Q * Q / p * Q / p) := by
  obtain ⟨r, hr, -⟩ := rateX96_le hlo (lt_trans hp (by unfold Q; norm_num))
  have hnp : ¬ Q ≤ p := by omega
  unfold rateX96 at hr ⊢
  simp only [hnp, ↓reduceIte] at hr ⊢
  obtain ⟨x, hx, hr'⟩ := Option.bind_eq_some_iff.1 hr
  rw [hx]
  change mulDivC x Q p = _
  rw [hr', (mulDivC_eq_some hr').2, (mulDivC_eq_some hx).2]

/-- Core bound for the converted token0 term when `p ≥ Q`. -/
theorem convert0_bound {L p x : ℚ} (hL : 0 ≤ L) (hL' : L ≤ 2 ^ 128) (hp : 2 ^ 96 ≤ p)
    (hp' : p ≤ 2 ^ 160) (_hx0 : 0 ≤ x) (hx : x ≤ L * 2 ^ 96 / p + 1) :
    x * (p * p / 2 ^ 96) / 2 ^ 96 < 2 ^ 193 := by
  have hp0 : 0 < p := lt_of_lt_of_le (by norm_num) hp
  calc x * (p * p / 2 ^ 96) / 2 ^ 96 ≤ (L * 2 ^ 96 / p + 1) * (p * p / 2 ^ 96) / 2 ^ 96 := by
        gcongr
    _ = L * p / 2 ^ 96 + p * p / 2 ^ 192 := by field_simp
    _ ≤ 2 ^ 128 * 2 ^ 160 / 2 ^ 96 + 2 ^ 160 * 2 ^ 160 / 2 ^ 192 := by gcongr
    _ < 2 ^ 193 := by norm_num

/-- Core bound for the converted token1 term when `p < Q`. -/
theorem convert1_bound {L p x r : ℚ} (hL : 0 ≤ L) (hL' : L ≤ 2 ^ 128) (hp : 2 ^ 32 ≤ p)
    (_hx0 : 0 ≤ x) (hx : x ≤ L * p / 2 ^ 96 + 1) (hr0 : 0 ≤ r)
    (hr : r ≤ 2 ^ 96 * 2 ^ 96 / p * 2 ^ 96 / p) :
    x * r / 2 ^ 96 < 2 ^ 193 := by
  have hp0 : 0 < p := lt_of_lt_of_le (by norm_num) hp
  calc x * r / 2 ^ 96 ≤ (L * p / 2 ^ 96 + 1) * (2 ^ 96 * 2 ^ 96 / p * 2 ^ 96 / p) / 2 ^ 96 := by
        gcongr
    _ = L * 2 ^ 96 / p + 2 ^ 192 / (p * p) := by field_simp
    _ ≤ 2 ^ 128 * 2 ^ 96 / 2 ^ 32 + 2 ^ 192 / (2 ^ 32 * 2 ^ 32) := by gcongr
    _ < 2 ^ 193 := by norm_num

/-- The rounded-up amounts for `L` never revert on a valid range, and each is bounded by its
    occupied interval: token0 over `[max(p, lo), hi]`, token1 over `[lo, min(p, hi)]`. -/
theorem roundingUp_bounds {p lo hi : ℕ} (hlo : 0 < lo) (hlh : lo < hi) (L : ℕ) :
    ∃ a0 a1, getAmountsForLiquidityRoundingUp p lo hi L = some (a0, a1) ∧
      a0 ≤ L * Q / max p lo + 1 ∧ a1 ≤ L * min p hi / Q + 1 := by
  unfold getAmountsForLiquidityRoundingUp
  by_cases h1 : p ≤ lo
  · have hmin : ¬ min lo hi = 0 := by rw [min_eq_left hlh.le]; omega
    simp only [h1, hmin, ↓reduceIte]
    refine ⟨_, _, rfl, ?_, Nat.zero_le _⟩
    rw [max_eq_right h1]
    exact amount0Up_le hlo hlh.le
  · by_cases h2 : p < hi
    · have hmin : ¬ min p hi = 0 := by rw [min_eq_left h2.le]; omega
      simp only [h1, h2, hmin, ↓reduceIte]
      refine ⟨_, _, rfl, ?_, ?_⟩
      · rw [max_eq_left (by omega)]
        exact amount0Up_le (by omega) h2.le
      · rw [min_eq_left h2.le]
        exact amount1Up_le (by omega)
    · simp only [h1, h2, ↓reduceIte]
      refine ⟨_, _, rfl, Nat.zero_le _, ?_⟩
      rw [min_eq_right (by omega)]
      exact amount1Up_le hlh.le

/-- **P5c.** For a valid price and range (`2^32 ≤ lo < hi < 2^160`, `2^32 ≤ p < 2^160`) and weights
    of at most `10^6`, the reference-position half of `getLiquidityForAmountsWeighted` never
    reverts: the rate, both reference amounts at `REFERENCE_LIQUIDITY`, and both token values are
    computed, and their sum (`refValue`) is below `2^194`, far from overflowing. -/
theorem referenceValue_fits {p lo hi w0 w1 : ℕ} (hlo : 2 ^ 32 ≤ lo) (hlh : lo < hi)
    (hhi : hi < 2 ^ 160) (hp : 2 ^ 32 ≤ p) (hp' : p < 2 ^ 160) (hw0 : w0 ≤ PIPS)
    (hw1 : w1 ≤ PIPS) :
    ∃ r ref0 ref1 v0 v1, rateX96 p = some r ∧
      getAmountsForLiquidityRoundingUp p lo hi REFERENCE_LIQUIDITY = some (ref0, ref1) ∧
      tokenValue ref0 w0 r (decide (Q ≤ p)) = some v0 ∧
      tokenValue ref1 w1 r (!decide (Q ≤ p)) = some v1 ∧
      v0 + v1 < 2 ^ 194 := by
  have hQ : Q = 2 ^ 96 := rfl
  have hU : (2 : ℕ) ^ 193 < U256 := by unfold U256; norm_num
  have hL : REFERENCE_LIQUIDITY ≤ 2 ^ 128 := by unfold REFERENCE_LIQUIDITY; omega
  set L := REFERENCE_LIQUIDITY
  obtain ⟨r, hr, hr224⟩ := rateX96_le hp hp'
  obtain ⟨ref0, ref1, href, hb0, hb1⟩ := roundingUp_bounds (p := p) (by omega) hlh L
  have hrw0 := rate_mul_weight_fits hr224 hw0
  have hrw1 := rate_mul_weight_fits hr224 hw1
  have fits : ∀ {x : ℕ}, chk x = some x → x < U256 := by
    intro x h; unfold chk at h; split_ifs at h with hx; exact hx
  -- casts of the occupied-interval bounds
  have hQq : (Q : ℚ) = 2 ^ 96 := by rw [hQ]; norm_num
  have hLq : (L : ℚ) ≤ 2 ^ 128 := by exact_mod_cast hL
  by_cases hpQ : Q ≤ p
  · -- token1 is cheaper: token0 is converted at r = p²/Q
    have hrv : r = p * p / Q := by
      rw [rateX96_eq_of_ge hpQ hp'] at hr; exact (Option.some.inj hr).symm
    have hx0 : (ref0 : ℚ) ≤ L * 2 ^ 96 / p + 1 := by
      have h1 : ((L * Q / max p lo : ℕ) : ℚ) ≤ (L * Q : ℕ) / (max p lo : ℕ) := Nat.cast_div_le
      have h2 : ((L * Q : ℕ) : ℚ) / (max p lo : ℕ) ≤ L * 2 ^ 96 / p := by
        push_cast; rw [hQq]
        gcongr
        exact_mod_cast le_max_left p lo
      have h3 : (ref0 : ℚ) ≤ ((L * Q / max p lo : ℕ) : ℚ) + 1 := by exact_mod_cast hb0
      linarith
    have hv0 : ref0 * r / Q < 2 ^ 193 := by
      have hc : ((ref0 * r / Q : ℕ) : ℚ) < 2 ^ 193 := by
        calc ((ref0 * r / Q : ℕ) : ℚ) ≤ ((ref0 * r : ℕ) : ℚ) / (Q : ℕ) := Nat.cast_div_le
          _ ≤ (ref0 : ℚ) * (p * p / 2 ^ 96) / 2 ^ 96 := by
            rw [hrv]; push_cast; rw [hQq]
            gcongr
            exact_mod_cast (by simpa [hQ] using (Nat.cast_div_le (α := ℚ) (m := p * p) (n := Q)))
          _ < 2 ^ 193 := convert0_bound (by positivity) hLq (by exact_mod_cast hpQ)
              (by exact_mod_cast hp'.le) (by positivity) hx0
      exact_mod_cast hc
    have hv1 : ref1 < 2 ^ 193 := by
      have : L * min p hi / Q ≤ 2 ^ 192 :=
        Nat.div_le_of_le_mul (by
          calc L * min p hi ≤ 2 ^ 128 * 2 ^ 160 :=
                Nat.mul_le_mul hL ((min_le_right p hi).trans hhi.le)
            _ = Q * 2 ^ 192 := by rw [hQ]; norm_num)
      omega
    obtain ⟨v0, hv0e, hv0le⟩ := tokenValue_convert hw0 (fits hrw0) (lt_trans hv0 hU)
    obtain ⟨v1, hv1e, hv1le⟩ := tokenValue_plain (r := r) hw1 (lt_trans hv1 hU)
    refine ⟨r, ref0, ref1, v0, v1, hr, href, ?_, ?_, by omega⟩
    · simpa [hpQ] using hv0e
    · simpa [hpQ] using hv1e
  · -- token0 is cheaper: token1 is converted at r = Q³/p²
    have hpQ' : p < Q := by omega
    have hrv : r = Q * Q / p * Q / p := by
      rw [rateX96_eq_of_lt hpQ' hp] at hr; exact (Option.some.inj hr).symm
    have hp0 : (0 : ℚ) < p := by exact_mod_cast (lt_of_lt_of_le (by norm_num) hp)
    have hx1 : (ref1 : ℚ) ≤ L * p / 2 ^ 96 + 1 := by
      have h1 : ((L * min p hi / Q : ℕ) : ℚ) ≤ (L * min p hi : ℕ) / (Q : ℕ) := Nat.cast_div_le
      have h2 : ((L * min p hi : ℕ) : ℚ) / (Q : ℕ) ≤ L * p / 2 ^ 96 := by
        push_cast; rw [hQq]
        gcongr
        exact_mod_cast min_le_left p hi
      have h3 : (ref1 : ℚ) ≤ ((L * min p hi / Q : ℕ) : ℚ) + 1 := by exact_mod_cast hb1
      linarith
    have hrq : (r : ℚ) ≤ 2 ^ 96 * 2 ^ 96 / p * 2 ^ 96 / p := by
      rw [hrv]
      calc ((Q * Q / p * Q / p : ℕ) : ℚ) ≤ ((Q * Q / p * Q : ℕ) : ℚ) / (p : ℕ) := Nat.cast_div_le
        _ = ((Q * Q / p : ℕ) : ℚ) * Q / p := by push_cast; ring
        _ ≤ ((Q * Q : ℕ) : ℚ) / (p : ℕ) * Q / p := by gcongr; exact Nat.cast_div_le
        _ = 2 ^ 96 * 2 ^ 96 / p * 2 ^ 96 / p := by push_cast; rw [hQq]
    have hv1 : ref1 * r / Q < 2 ^ 193 := by
      have hc : ((ref1 * r / Q : ℕ) : ℚ) < 2 ^ 193 := by
        calc ((ref1 * r / Q : ℕ) : ℚ) ≤ ((ref1 * r : ℕ) : ℚ) / (Q : ℕ) := Nat.cast_div_le
          _ = (ref1 : ℚ) * r / 2 ^ 96 := by push_cast; rw [hQq]
          _ < 2 ^ 193 := convert1_bound (by positivity) hLq (by exact_mod_cast hp) (by positivity)
              hx1 (by positivity) hrq
      exact_mod_cast hc
    have hv0 : ref0 < 2 ^ 193 := by
      have : L * Q / max p lo ≤ 2 ^ 192 := by
        calc L * Q / max p lo ≤ L * Q / 2 ^ 32 := Nat.div_le_div_left (hlo.trans (le_max_right _ _))
              (by norm_num)
          _ ≤ 2 ^ 128 * Q / 2 ^ 32 := by gcongr
          _ = 2 ^ 192 := by rw [hQ]; norm_num
      omega
    obtain ⟨v0, hv0e, hv0le⟩ := tokenValue_plain (r := r) hw0 (lt_trans hv0 hU)
    obtain ⟨v1, hv1e, hv1le⟩ := tokenValue_convert hw1 (fits hrw1) (lt_trans hv1 hU)
    refine ⟨r, ref0, ref1, v0, v1, hr, href, ?_, ?_, by omega⟩
    · simpa [hpQ] using hv0e
    · simpa [hpQ] using hv1e

/-- **P5d.** On valid inputs the reference half is a fixed, non-reverting computation, so
    `getLiquidityForAmountsWeighted` reduces to its budget half: value the budgets, then scale. Its
    only reverts are the budget valuation overflowing (a token value or their sum) and the result
    not fitting in `uint128`. -/
theorem weighted_eq_budget_side {p lo hi w0 w1 : ℕ} (hlo : 2 ^ 32 ≤ lo) (hlh : lo < hi)
    (hhi : hi < 2 ^ 160) (hp : 2 ^ 32 ≤ p) (hp' : p < 2 ^ 160) (hw0 : w0 ≤ PIPS)
    (hw1 : w1 ≤ PIPS) :
    ∃ r refValue, refValue < 2 ^ 194 ∧ ∀ a0 a1,
      getLiquidityForAmountsWeighted p lo hi a0 a1 w0 w1 =
        if refValue = 0 then some 0 else (do
          let budgetValue ← chk ((← tokenValue a0 w0 r (decide (Q ≤ p))) +
            (← tokenValue a1 w1 r (!decide (Q ≤ p))))
          toUint128 (← mulDivC budgetValue REFERENCE_LIQUIDITY refValue)) := by
  obtain ⟨r, ref0, ref1, v0, v1, hr, href, hv0, hv1, hsum⟩ :=
    referenceValue_fits hlo hlh hhi hp hp' hw0 hw1
  have hlt : v0 + v1 < U256 := lt_trans hsum (by unfold U256; norm_num)
  have hchk : chk (v0 + v1) = some (v0 + v1) := by simp only [chk, hlt, ↓reduceIte]
  refine ⟨r, v0 + v1, hsum, fun a0 a1 => ?_⟩
  simp only [getLiquidityForAmountsWeighted, hr, href, hv0, hv1, hchk, Option.bind_eq_bind,
    Option.bind_some]
  rfl

/-- A token value is monotone in the amount: if a larger amount's value is computed, so is a
    smaller one's, and it is no larger. -/
theorem tokenValue_mono {a a' w r : ℕ} {c : Bool} {v' : ℕ} (h : a ≤ a')
    (hv' : tokenValue a' w r c = some v') : ∃ v, tokenValue a w r c = some v ∧ v ≤ v' := by
  have key : ∀ {b d x' : ℕ}, mulDivC a' b d = some x' →
      ∃ x, mulDivC a b d = some x ∧ x ≤ x' := by
    intro b d x' hx'
    obtain ⟨hd, rfl⟩ := mulDivC_eq_some hx'
    have hle : a * b / d ≤ a' * b / d := Nat.div_le_div_right (Nat.mul_le_mul_right b h)
    have hfit : a' * b / d < U256 := by
      unfold mulDivC chk mulDiv at hx'; split_ifs at hx' with h1 h2; exact h2
    exact ⟨_, by simp [mulDivC, chk, mulDiv, hd.ne', lt_of_le_of_lt hle hfit], hle⟩
  cases c with
  | false =>
    simp only [tokenValue, Bool.false_eq_true, ↓reduceIte] at hv' ⊢
    exact key hv'
  | true =>
    simp only [tokenValue, ↓reduceIte] at hv' ⊢
    obtain ⟨rw', hrw, hx⟩ := Option.bind_eq_some_iff.1 hv'
    rw [hrw]
    exact key hx

theorem toUint128_of_lt {x : ℕ} (h : x < U128) : toUint128 x = some x := by
  unfold toUint128; split_ifs; rfl

/-- **P5d (no revert).** On valid inputs, budgets no larger than the reference amounts (what a
    `type(uint128).max` position would need at this price) never revert, and size to at most
    `REFERENCE_LIQUIDITY`. -/
theorem weighted_fits_of_le_reference {p lo hi w0 w1 a0 a1 ref0 ref1 : ℕ} (hlo : 2 ^ 32 ≤ lo)
    (hlh : lo < hi) (hhi : hi < 2 ^ 160) (hp : 2 ^ 32 ≤ p) (hp' : p < 2 ^ 160) (hw0 : w0 ≤ PIPS)
    (hw1 : w1 ≤ PIPS)
    (href : getAmountsForLiquidityRoundingUp p lo hi REFERENCE_LIQUIDITY = some (ref0, ref1))
    (ha0 : a0 ≤ ref0) (ha1 : a1 ≤ ref1) :
    ∃ L, getLiquidityForAmountsWeighted p lo hi a0 a1 w0 w1 = some L ∧ L ≤ REFERENCE_LIQUIDITY := by
  obtain ⟨r, ref0', ref1', v0, v1, hr, href', hv0, hv1, hsum⟩ :=
    referenceValue_fits hlo hlh hhi hp hp' hw0 hw1
  rw [href] at href'
  obtain ⟨rfl, rfl⟩ := Prod.mk.inj (Option.some.inj href')
  obtain ⟨u0, hu0, hu0le⟩ := tokenValue_mono ha0 hv0
  obtain ⟨u1, hu1, hu1le⟩ := tokenValue_mono ha1 hv1
  have hU : ∀ x, x < 2 ^ 194 → x < U256 := fun x hx =>
    lt_trans hx (by unfold U256; norm_num)
  have hchk : ∀ x, x < 2 ^ 194 → chk x = some x := fun x hx => by simp [chk, hU x hx]
  have hRef : REFERENCE_LIQUIDITY < U128 := by unfold REFERENCE_LIQUIDITY U128; omega
  have hRefU : REFERENCE_LIQUIDITY < U256 := by unfold REFERENCE_LIQUIDITY U256; norm_num
  simp only [getLiquidityForAmountsWeighted, hr, href, hv0, hv1, hu0, hu1,
    hchk _ hsum, hchk (u0 + u1) (by omega), Option.bind_eq_bind, Option.bind_some]
  split_ifs with hz
  · exact ⟨0, rfl, Nat.zero_le _⟩
  · have hle : (u0 + u1) * REFERENCE_LIQUIDITY / (v0 + v1) ≤ REFERENCE_LIQUIDITY :=
      Nat.div_le_of_le_mul (Nat.mul_le_mul_right REFERENCE_LIQUIDITY (by omega : u0 + u1 ≤ v0 + v1))
    have hm : mulDivC (u0 + u1) REFERENCE_LIQUIDITY (v0 + v1) =
        some ((u0 + u1) * REFERENCE_LIQUIDITY / (v0 + v1)) := by
      simp only [mulDivC, chk, mulDiv, hz, lt_of_le_of_lt hle hRefU, ↓reduceIte]
    have hfit : (u0 + u1) * REFERENCE_LIQUIDITY / (v0 + v1) < U128 := lt_of_le_of_lt hle hRef
    refine ⟨(u0 + u1) * REFERENCE_LIQUIDITY / (v0 + v1), ?_, hle⟩
    rw [hm, Option.bind_some, toUint128_of_lt hfit]

/-! ## P4: fee-aware sizing -/

/-- `getAmountsForLiquidityRoundingUp` never reverts when both range bounds are positive. -/
theorem roundingUp_isSome {p lo hi : ℕ} (hlo : 0 < lo) (hhi : 0 < hi) (L : ℕ) :
    ∃ a, getAmountsForLiquidityRoundingUp p lo hi L = some a := by
  unfold getAmountsForLiquidityRoundingUp
  split_ifs with h1 h2 h3 h4 <;> first | exact ⟨_, rfl⟩ | omega

/-- **P4a.** When the swap fee is zero in both directions, fee-aware sizing returns exactly the
    mid-price sizing: the discount only ever comes from the fee. -/
theorem feeAware_zero_fee {p lo hi b0 b1 pf lf : ℕ} (hlo : 0 < lo) (hhi : 0 < hi)
    (h0 : calculateSwapFee (getZeroForOneFee pf) lf = 0)
    (h1 : calculateSwapFee (getOneForZeroFee pf) lf = 0) :
    getLiquidityFeeAware p lo hi b0 b1 pf lf =
      getLiquidityForAmountsWeighted p lo hi b0 b1 PIPS PIPS := by
  unfold getLiquidityFeeAware
  cases hm : getLiquidityForAmountsWeighted p lo hi b0 b1 PIPS PIPS with
  | none => rfl
  | some mid =>
    obtain ⟨⟨m0, m1⟩, ha⟩ := roundingUp_isSome (p := p) hlo hhi mid
    simp only [Option.bind_eq_bind, Option.bind_some, ha, h0, h1, subC, Nat.zero_le, ↓reduceIte,
      Nat.sub_zero]
    split_ifs <;> first | exact hm | rfl

/-! ## P7: the trim cap -/

/-- **P7.** The trim never removes more than the liquidity added in this transaction. -/
theorem trimCap_le (t : Option ℕ) (lopt : ℕ) : trimCap t lopt ≤ lopt := by
  cases t with
  | none => simp [trimCap]
  | some T =>
    simp only [trimCap]
    split_ifs <;> omega

/-- **P7 (cast).** The `uint128(liquidityToTrim)` cast only runs when `liquidityToTrim < lopt`, and
    `lopt` is a `uint128`, so the cast never truncates. -/
theorem trimCap_cast_exact {T lopt : ℕ} (hlopt : lopt < 2 ^ 128) (h : ¬ lopt ≤ T) :
    T < 2 ^ 128 := by
  omega

end SwapAndAddFV
