import SwapAndAddFV.Assumptions
import SwapAndAddFV.TickMath

/-!
# TickMath reference values

Values the model must reproduce. Each is checked by Lean's kernel evaluating the model.
-/

namespace SwapAndAddFV

/-- `getSqrtPriceAtTick(MIN_TICK) = MIN_SQRT_PRICE`. -/
theorem sqrtPriceAtMinTick : getSqrtPriceAtTick (-887272) = some MIN_SQRT_PRICE := by decide

/-- `getSqrtPriceAtTick(MAX_TICK) = MAX_SQRT_PRICE`. -/
theorem sqrtPriceAtMaxTick : getSqrtPriceAtTick 887272 = some MAX_SQRT_PRICE := by decide

/-- Tick 0 is price 1: `getSqrtPriceAtTick(0) = Q`. -/
theorem sqrtPriceAtZero : getSqrtPriceAtTick 0 = some Q := by decide

/-- The tick-1 price used for the pinned OZ N-08 case. -/
theorem sqrtPriceAtOne : getSqrtPriceAtTick 1 = some 79232123823359799118286999568 := by decide

/-- One past either end reverts. -/
theorem sqrtPriceOutOfRange :
    getSqrtPriceAtTick 887273 = none ∧ getSqrtPriceAtTick (-887273) = none := by decide

end SwapAndAddFV
