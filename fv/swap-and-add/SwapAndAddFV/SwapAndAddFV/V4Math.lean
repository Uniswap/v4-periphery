/-!
# v4-core arithmetic (SPEC.md D1–D4)

Exact models of the v4-core functions SwapAndAddMath depends on, pinned to v4-core
`59d3ecf53afa9264a16bba0e38f4c5d2231f80bc`. Values are unbounded naturals: these definitions
describe what each function returns when it does not revert. Revert conditions are stated
separately where a property needs them.

This module has no Mathlib dependency so the test vector generator can run it without compiling
Mathlib. Assumptions and proofs live in `Assumptions.lean` and onward.
-/

namespace SwapAndAddFV

/-- `FixedPoint96.Q96`. -/
def Q : Nat := 2 ^ 96

/-- D1. `FullMath.mulDiv(a, b, d)`: `⌊a·b/d⌋`. -/
def mulDiv (a b d : Nat) : Nat := a * b / d

/-- D1. `FullMath.mulDivRoundingUp(a, b, d)`: `mulDiv`, plus one when `mulmod(a, b, d) > 0`. -/
def mulDivUp (a b d : Nat) : Nat := a * b / d + if a * b % d = 0 then 0 else 1

/-- `UnsafeMath.divRoundingUp(x, y)`: `x / y`, plus one when `x % y > 0`. -/
def divUp (x y : Nat) : Nat := x / y + if x % y = 0 then 0 else 1

/-- D2. `SqrtPriceMath.getAmount0Delta(a, b, L, roundUp)`. The prices are sorted first, then
    `L << 96` (`= L·Q`) is divided by the upper price and then by the lower price. -/
def getAmount0Delta (a b L : Nat) (roundUp : Bool) : Nat :=
  if roundUp then divUp (mulDivUp (L * Q) (max a b - min a b) (max a b)) (min a b)
  else mulDiv (L * Q) (max a b - min a b) (max a b) / min a b

/-- D3. `SqrtPriceMath.getAmount1Delta(a, b, L, roundUp)`: `L·|b − a| / Q`. -/
def getAmount1Delta (a b L : Nat) (roundUp : Bool) : Nat :=
  if roundUp then mulDivUp L (max a b - min a b) Q else mulDiv L (max a b - min a b) Q

/-- The pool state a position's amounts depend on: the tick-to-sqrt-price map
    (`TickMath.getSqrtPriceAtTick`) and `slot0`'s tick and sqrt price. -/
structure PoolState where
  sqrtAt : Int → Nat
  tick : Int
  sqrtPrice : Nat

/-- D4. The token amounts `Pool.modifyLiquidity` moves for `L` liquidity in
    `[tickLower, tickUpper)`. Adding charges them rounded up (`roundUp = true`); removing pays
    them rounded down (`roundUp = false`). Branches on the tick, as the pool does. -/
def positionAmounts (s : PoolState) (tickLower tickUpper : Int) (L : Nat) (roundUp : Bool) :
    Nat × Nat :=
  if s.tick < tickLower then
    (getAmount0Delta (s.sqrtAt tickLower) (s.sqrtAt tickUpper) L roundUp, 0)
  else if s.tick < tickUpper then
    (getAmount0Delta s.sqrtPrice (s.sqrtAt tickUpper) L roundUp,
      getAmount1Delta (s.sqrtAt tickLower) s.sqrtPrice L roundUp)
  else
    (0, getAmount1Delta (s.sqrtAt tickLower) (s.sqrtAt tickUpper) L roundUp)

end SwapAndAddFV
