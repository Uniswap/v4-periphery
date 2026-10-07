import SwapAndAddFV.V4Math

/-!
# SwapAndAddMath model

Models of the functions in `src/libraries/SwapAndAddMath.sol` at `756be37c`, and of the sizing
arithmetic in `SwapAndAdd._planLiquidity`.

Except for `getLiquidityToTrim`, these models track reverts: `none` means the Solidity reverts
(division by zero, a checked overflow or underflow, a failed cast, or `FullMath` overflowing 256
bits), and `some x` means it returns `x`.
-/

namespace SwapAndAddFV

/-- `SwapAndAddMath.getLiquidityToTrim(p, lo, hi, deficitIsCurrency1, d)`.
    `none` stands for the `type(uint256).max` sentinel returned when no finite burn frees any of
    the shortfall token. -/
def getLiquidityToTrim (p lo hi : Nat) (deficitIsCurrency1 : Bool) (d : Nat) : Option Nat :=
  if deficitIsCurrency1 then
    if p ≤ lo then none
    -- token1 occupies [lo, min(p, hi)]
    else some (mulDivUp d Q (min p hi - lo))
  else
    if hi ≤ p then none
    -- token0 occupies [max(p, lo), hi]
    else if hi ≤ Q then
      some (mulDivUp d (max p lo * hi) ((hi - max p lo) * Q))
    else
      some (mulDivUp d (mulDivUp (max p lo) hi Q) (hi - max p lo))

/-- The trim cap in `SwapAndAdd._trim`:
    `dl = liquidityToTrim >= lopt ? lopt : uint128(liquidityToTrim)`, where `lopt` is the liquidity
    added in this transaction. The `none` sentinel (`type(uint256).max`) always takes the cap. -/
def trimCap (liquidityToTrim : Option Nat) (lopt : Nat) : Nat :=
  match liquidityToTrim with
  | none => lopt
  | some T => if lopt ≤ T then lopt else T

/-! ## Checked uint256 arithmetic -/

def U256 : Nat := 2 ^ 256

/-- `SwapAndAddMath.PIPS_DENOMINATOR` (and `ProtocolFeeLibrary.PIPS_DENOMINATOR`). -/
def PIPS : Nat := 1000000

/-- `SwapAndAddMath.REFERENCE_LIQUIDITY`, `type(uint128).max`. -/
def REFERENCE_LIQUIDITY : Nat := 2 ^ 128 - 1

/-- A value that must fit in a uint256, as after a checked `+` or `*`. -/
def chk (x : Nat) : Option Nat := if x < U256 then some x else none

/-- Checked `a - b`. -/
def subC (a b : Nat) : Option Nat := if b ≤ a then some (a - b) else none

/-- `FullMath.mulDiv`, reverting on a zero denominator or a result of 256 bits or more. -/
def mulDivC (a b d : Nat) : Option Nat := if d = 0 then none else chk (mulDiv a b d)

/-- `2^128`, the bound of a `uint128`. -/
def U128 : Nat := 2 ^ 128

/-- `SafeCast.toUint128`. -/
def toUint128 (x : Nat) : Option Nat := if x < U128 then some x else none

/-! ## Fees (D5) -/

/-- `ProtocolFeeLibrary.getZeroForOneFee`: the low 12 bits. -/
def getZeroForOneFee (protocolFee : Nat) : Nat := protocolFee % 4096

/-- `ProtocolFeeLibrary.getOneForZeroFee`: the high 12 bits of the uint24. -/
def getOneForZeroFee (protocolFee : Nat) : Nat := protocolFee / 4096

/-- `ProtocolFeeLibrary.calculateSwapFee`: `s + l − ⌊s·l/10^6⌋` on the masked inputs. The
    assembly subtraction cannot wrap: `⌊s·l/10^6⌋ ≤ l` because `s < 10^6`. -/
def calculateSwapFee (protocolFee lpFee : Nat) : Nat :=
  let s := protocolFee % 4096
  let l := lpFee % 2 ^ 24
  s + l - s * l / PIPS

/-! ## Sizing -/

/-- `SwapAndAddMath.getAmountsForLiquidityRoundingUp`. Reverts only when a lower price passed to
    `getAmount0Delta` is zero. -/
def getAmountsForLiquidityRoundingUp (p lo hi L : Nat) : Option (Nat × Nat) :=
  if p ≤ lo then
    if min lo hi = 0 then none else some (getAmount0Delta lo hi L true, 0)
  else if p < hi then
    if min p hi = 0 then none
    else some (getAmount0Delta p hi L true, getAmount1Delta lo p L true)
  else
    some (0, getAmount1Delta lo hi L true)

/-- `SwapAndAddMath._tokenValue`. `rate * pipsWeight` is a checked multiplication. -/
def tokenValue (amount pipsWeight rate : Nat) (convert : Bool) : Option Nat :=
  if convert then do
    let rw ← chk (rate * pipsWeight)
    mulDivC amount rw (Q * PIPS)
  else mulDivC amount pipsWeight PIPS

/-- The `rateX96` of `getLiquidityForAmountsWeighted`: the price `p²/Q` when token1 is cheaper or
    equal (`p ≥ Q`), else its inverse `Q³/p²`, each floored as the code does. -/
def rateX96 (p : Nat) : Option Nat :=
  if Q ≤ p then mulDivC p p Q
  else do
    let x ← mulDivC Q Q p
    mulDivC x Q p

/-- `SwapAndAddMath.getLiquidityForAmountsWeighted`. -/
def getLiquidityForAmountsWeighted (p lo hi amount0 amount1 pipsWeight0 pipsWeight1 : Nat) :
    Option Nat := do
  let token1Cheaper := decide (Q ≤ p)
  let rate ← rateX96 p
  let (ref0, ref1) ← getAmountsForLiquidityRoundingUp p lo hi REFERENCE_LIQUIDITY
  let refValue ← chk ((← tokenValue ref0 pipsWeight0 rate token1Cheaper) +
    (← tokenValue ref1 pipsWeight1 rate (!token1Cheaper)))
  if refValue = 0 then return 0
  let budgetValue ← chk ((← tokenValue amount0 pipsWeight0 rate token1Cheaper) +
    (← tokenValue amount1 pipsWeight1 rate (!token1Cheaper)))
  toUint128 (← mulDivC budgetValue REFERENCE_LIQUIDITY refValue)

/-- `SwapAndAddMath.getLiquidityFeeAware`. -/
def getLiquidityFeeAware (p lo hi budget0 budget1 protocolFee lpFee : Nat) : Option Nat := do
  let mid ← getLiquidityForAmountsWeighted p lo hi budget0 budget1 PIPS PIPS
  let (mid0, mid1) ← getAmountsForLiquidityRoundingUp p lo hi mid
  if mid0 < budget0 then
    let w ← subC PIPS (calculateSwapFee (getZeroForOneFee protocolFee) lpFee)
    getLiquidityForAmountsWeighted p lo hi budget0 budget1 w PIPS
  else if mid1 < budget1 then
    let w ← subC PIPS (calculateSwapFee (getOneForZeroFee protocolFee) lpFee)
    getLiquidityForAmountsWeighted p lo hi budget0 budget1 PIPS w
  else return mid

/-- The arithmetic of `SwapAndAdd._planLiquidity` after its price checks: size, compute the
    rounded-up amounts, and step down one unit of liquidity if both amounts exceed the budgets.
    Returns `(liquidity, amount0, amount1)`. -/
def planLiquidity (p lo hi budget0 budget1 protocolFee lpFee : Nat) :
    Option (Nat × Nat × Nat) := do
  let L ← getLiquidityFeeAware p lo hi budget0 budget1 protocolFee lpFee
  let (a0, a1) ← getAmountsForLiquidityRoundingUp p lo hi L
  if budget0 < a0 ∧ budget1 < a1 then
    let L' ← subC L 1
    let (b0, b1) ← getAmountsForLiquidityRoundingUp p lo hi L'
    return (L', b0, b1)
  else return (L, a0, a1)

end SwapAndAddFV
