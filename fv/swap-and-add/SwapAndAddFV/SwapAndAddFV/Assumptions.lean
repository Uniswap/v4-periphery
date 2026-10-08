import Mathlib
import SwapAndAddFV.V4Math

/-!
# Assumptions (SPEC.md A1, A2)
-/

namespace SwapAndAddFV

theorem Q_pos : 0 < Q := by unfold Q; positivity

/-- SPEC.md A1 and A2: tick-to-price is strictly increasing and positive, the range is
    non-empty, and `slot0`'s price lies between its tick's price and the next tick's. -/
structure WellFormed (s : PoolState) (tickLower tickUpper : ℤ) : Prop where
  strictMono : StrictMono s.sqrtAt
  pos : ∀ t, 0 < s.sqrtAt t
  range : tickLower < tickUpper
  slot0_lower : s.sqrtAt s.tick ≤ s.sqrtPrice
  slot0_upper : s.sqrtPrice ≤ s.sqrtAt (s.tick + 1)

end SwapAndAddFV
