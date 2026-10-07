import SwapAndAddFV.SwapAndAddMath
import SwapAndAddFV.TickMath

/-!
# Test vector generator

Writes `../vectors/*.json`: inputs drawn from a fixed-seed generator, with the Lean model's
outputs. `test/SwapAndAddMathLeanModel.t.sol` replays them against the Solidity, so a passing test
means the model and the code agree on every vector.

Regenerate with `lake exe vectors` from this directory.
-/

open SwapAndAddFV

/-- Generator state for splitmix64. -/
abbrev Gen := StateM UInt64

def word : Gen Nat := modifyGet fun (s : UInt64) =>
  let s := s + 0x9E3779B97F4A7C15
  let z : UInt64 := (s ^^^ (s >>> 30)) * 0xBF58476D1CE4E5B9
  let z : UInt64 := (z ^^^ (z >>> 27)) * 0x94D049BB133111EB
  ((z ^^^ (z >>> 31)).toNat, s)

/-- Uniform below `2^n`. -/
def bits (n : Nat) : Gen Nat := do
  let mut acc := 0
  for _ in [0:(n + 63) / 64] do
    acc := acc * 2 ^ 64 + (← word)
  return acc % 2 ^ n

/-- Uniform below `n` (approximately; `n > 0`). -/
def below (n : Nat) : Gen Nat := do return (← bits (Nat.log2 n + 64)) % n

/-- A random bit length in `[lo, hi]`, then a uniform value of that length: spreads values across
    magnitudes. -/
def logUniform (lo hi : Nat) : Gen Nat := do bits (lo + (← below (hi - lo + 1)))


/-- A valid sqrt price, `[MIN_SQRT_PRICE, MAX_SQRT_PRICE]`, of random magnitude. -/
def price : Gen Nat := do
  let x ← logUniform 32 160
  return MIN_SQRT_PRICE + x % (MAX_SQRT_PRICE - MIN_SQRT_PRICE + 1)

/-- Range bounds `lo < hi`, sometimes very narrow. -/
def range : Gen (Nat × Nat) := do
  let a ← price
  if (← below 4) == 0 then
    let w ← logUniform 0 20
    let lo := min a (MAX_SQRT_PRICE - w - 1)
    return (lo, lo + w + 1)
  let b ← price
  if a == b then return (a, a + 1) else return (min a b, max a b)

/-- A pool price relative to `[lo, hi]`, biased toward the boundaries. -/
def priceAround (lo hi : Nat) : Gen Nat := do
  match ← below 9 with
  | 0 => return MIN_SQRT_PRICE + (← below (lo - MIN_SQRT_PRICE + 1))
  | 1 => return lo
  | 2 => return lo + 1
  | 3 => return lo + 1 + (← below (hi - lo))
  | 4 => return hi - 1
  | 5 => return hi
  | 6 => return hi + 1
  | 7 => return hi + (← below (MAX_SQRT_PRICE - hi + 1))
  | _ => price

def amountToCover : Gen Nat := do
  match ← below 6 with
  | 0 => return 0
  | 1 => return 1
  | 2 => return 2 ^ 128 - 1
  | 3 => return U256 - 1
  | 4 => logUniform 0 128
  | _ => logUniform 0 256

def hex (n : Nat) : String := "\"0x" ++ String.ofList (Nat.toDigits 16 n) ++ "\""

def jsonArray (xs : Array String) : String := "[" ++ ",".intercalate xs.toList ++ "]"

def jsonObject (fields : List (String × Array String)) : String :=
  "{" ++ ",".intercalate (fields.map fun (k, v) => s!"\"{k}\":{jsonArray v}") ++ "}\n"

/-- `getLiquidityToTrim` vectors. Expected output: the sentinel `2^256 − 1` for `none`, and a
    revert when the result does not fit in 256 bits (`FullMath.mulDivRoundingUp` overflow). -/
def trimVectors (n : Nat) : Gen String := do
  let mut cols : Array (Array String) := #[#[], #[], #[], #[], #[], #[], #[]]
  for _ in [0:n] do
    let (lo, hi) ← range
    let p ← priceAround lo hi
    let one := (← below 2) == 1
    let d ← amountToCover
    let (expected, reverts) := match getLiquidityToTrim p lo hi one d with
      | none => (U256 - 1, false)
      | some T => if T < U256 then (T, false) else (0, true)
    let row := #[hex p, hex lo, hex hi, toString one, hex d, hex expected, toString reverts]
    cols := (cols.zip row).map fun (c, x) => c.push x
  return jsonObject (["p", "lo", "hi", "deficitIsCurrency1", "d", "expected", "reverts"].zip
    cols.toList)

/-- `SqrtPriceMath.getAmount0Delta` / `getAmount1Delta` vectors, both rounding directions. -/
def amountVectors (n : Nat) : Gen String := do
  let mut cols : Array (Array String) := #[#[], #[], #[], #[], #[], #[], #[]]
  for _ in [0:n] do
    let (lo, hi) ← range
    let (a, b) ← match ← below 4 with
      | 0 => pure (hi, lo)
      | 1 => pure (lo, lo)
      | _ => pure (lo, hi)
    let L ← logUniform 0 128
    let row := #[hex a, hex b, hex L,
      hex (getAmount0Delta a b L true), hex (getAmount0Delta a b L false),
      hex (getAmount1Delta a b L true), hex (getAmount1Delta a b L false)]
    cols := (cols.zip row).map fun (c, x) => c.push x
  return jsonObject (["a", "b", "liquidity", "amount0Up", "amount0Down", "amount1Up",
    "amount1Down"].zip cols.toList)

/-- Builds a JSON object of columns from rows. -/
def table (names : List String) (rows : Array (List String)) : String :=
  jsonObject ((List.range names.length).zip names |>.map fun (i, k) => (k, rows.map fun r => r.getD i ""))

/-- An `Option` result as `(value, reverts)` columns. -/
def outcome (r : Option Nat) : List String :=
  match r with
  | some x => [hex x, "false"]
  | none => [hex 0, "true"]

/-- A protocol fee with two 12-bit halves, mostly within `MAX_PROTOCOL_FEE = 1000`. -/
def protocolFee : Gen Nat := do
  let half : Gen Nat := do
    match ← below 4 with
    | 0 => return 0
    | 1 => return 1000
    | 2 => below 4096
    | _ => below 1001
  return (← half) + 4096 * (← half)

/-- An LP fee within `MAX_LP_FEE = 10^6` (SPEC.md A3). -/
def lpFee : Gen Nat := do
  match ← below 5 with
  | 0 => return 0
  | 1 => return PIPS
  | 2 => return PIPS - 1
  | _ => below (PIPS + 1)

/-- A pips weight in `[0, 10^6]`, biased toward the ends. -/
def pipsWeight : Gen Nat := do
  match ← below 4 with
  | 0 => return PIPS
  | 1 => return 0
  | _ => below (PIPS + 1)

/-- Token budgets: sometimes close to an exact position's amounts (the no-swap branch), otherwise
    of random magnitude, sometimes single-sided. -/
def budgets (p lo hi : Nat) : Gen (Nat × Nat) := do
  match ← below 5 with
  | 0 =>
    let L ← logUniform 0 127
    match getAmountsForLiquidityRoundingUp p lo hi L with
    | some (a0, a1) => return (a0 + (← below 3), a1 + (← below 3))
    | none => return (0, 0)
  | 1 => return (← logUniform 0 160, 0)
  | 2 => return (0, ← logUniform 0 160)
  | 3 => return (← logUniform 0 256, ← logUniform 0 256)
  | _ => return (← logUniform 0 128, ← logUniform 0 128)

def feeVectors (n : Nat) : Gen String := do
  let mut rows := #[]
  for _ in [0:n] do
    let pf ← protocolFee
    let lf ← lpFee
    rows := rows.push [hex pf, hex lf,
      hex (calculateSwapFee (getZeroForOneFee pf) lf),
      hex (calculateSwapFee (getOneForZeroFee pf) lf)]
  return table ["protocolFee", "lpFee", "zeroForOneFee", "oneForZeroFee"] rows

def roundingUpVectors (n : Nat) : Gen String := do
  let mut rows := #[]
  for _ in [0:n] do
    let (lo, hi) ← range
    let p ← priceAround lo hi
    let L ← logUniform 0 128
    let (a0, a1, reverts) := match getAmountsForLiquidityRoundingUp p lo hi L with
      | some (a0, a1) => (a0, a1, false)
      | none => (0, 0, true)
    rows := rows.push [hex p, hex lo, hex hi, hex L, hex a0, hex a1, toString reverts]
  return table ["p", "lo", "hi", "liquidity", "amount0", "amount1", "reverts"] rows

def weightedVectors (n : Nat) : Gen String := do
  let mut rows := #[]
  for _ in [0:n] do
    let (lo, hi) ← range
    let p ← priceAround lo hi
    let (b0, b1) ← budgets p lo hi
    let w0 ← pipsWeight
    let w1 ← pipsWeight
    rows := rows.push ([hex p, hex lo, hex hi, hex b0, hex b1, hex w0, hex w1] ++
      outcome (getLiquidityForAmountsWeighted p lo hi b0 b1 w0 w1))
  return table ["p", "lo", "hi", "amount0", "amount1", "pipsWeight0", "pipsWeight1", "expected",
    "reverts"] rows

def feeAwareVectors (n : Nat) : Gen String := do
  let mut rows := #[]
  for _ in [0:n] do
    let (lo, hi) ← range
    let p ← priceAround lo hi
    let (b0, b1) ← budgets p lo hi
    let pf ← protocolFee
    let lf ← lpFee
    rows := rows.push ([hex p, hex lo, hex hi, hex b0, hex b1, hex pf, hex lf] ++
      outcome (getLiquidityFeeAware p lo hi b0 b1 pf lf))
  return table ["p", "lo", "hi", "budget0", "budget1", "protocolFee", "lpFee", "expected",
    "reverts"] rows

/-- A tick: mostly valid, biased toward the ends, bit boundaries, and just out of range. -/
def tick : Gen Int := do
  let mag : Nat ← match ← below 8 with
    | 0 => pure MAX_TICK
    | 1 => pure (MAX_TICK + 1)
    | 2 => pure (← below 4)
    | 3 => pure (2 ^ (← below 20))
    | 4 => pure (2 ^ (← below 20) - 1)
    | 5 => pure (MAX_TICK + 1 + (← below (2 ^ 23 - MAX_TICK - 1)))
    | _ => below (MAX_TICK + 1)
  return if (← below 2) == 0 then Int.ofNat mag else -Int.ofNat mag

/-- `TickMath.getSqrtPriceAtTick` vectors. -/
def tickVectors (n : Nat) : Gen String := do
  let mut rows := #[]
  for _ in [0:n] do
    let t ← tick
    rows := rows.push ([s!"\"{t}\""] ++ outcome (getSqrtPriceAtTick t))
  return table ["tick", "expected", "reverts"] rows

def main : IO Unit := do
  let (trim, s) := (trimVectors 1000).run 1
  let (amounts, s) := (amountVectors 1000).run s
  let (fees, s) := (feeVectors 1000).run s
  let (roundingUp, s) := (roundingUpVectors 1000).run s
  let (weighted, s) := (weightedVectors 1000).run s
  let (feeAware, s) := (feeAwareVectors 1000).run s
  let (ticks, _) := (tickVectors 2000).run s
  IO.FS.createDirAll "../vectors"
  for (name, json) in [("trim", trim), ("amounts", amounts), ("fees", fees),
      ("roundingUp", roundingUp), ("weighted", weighted), ("feeAware", feeAware), ("ticks", ticks)] do
    IO.FS.writeFile s!"../vectors/{name}.json" json
    IO.println s!"wrote ../vectors/{name}.json"
