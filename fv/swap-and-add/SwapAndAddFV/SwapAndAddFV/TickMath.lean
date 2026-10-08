/-!
# TickMath model

`TickMath.getSqrtPriceAtTick` from v4-core `59d3ecf53afa9264a16bba0e38f4c5d2231f80bc`, operation by
operation. No Mathlib dependency, so the vector generator can run it.
-/

namespace SwapAndAddFV

/-- `TickMath.MIN_TICK` / `MAX_TICK` (as magnitudes; the range is symmetric). -/
def MAX_TICK : Nat := 887272

/-- `TickMath.MIN_SQRT_PRICE` and `MAX_SQRT_PRICE`. -/
def MIN_SQRT_PRICE : Nat := 4295128739
def MAX_SQRT_PRICE : Nat := 1461446703485210103287273052203988822378723970342

/-- The Q128.128 factors `1/sqrt(1.0001^(2^i))` for bits `i = 1 … 19` of `|tick|`, in code order. -/
def tickFactors : List (Nat × Nat) :=
  [(0x2, 0xfff97272373d413259a46990580e213a),
   (0x4, 0xfff2e50f5f656932ef12357cf3c7fdcc),
   (0x8, 0xffe5caca7e10e4e61c3624eaa0941cd0),
   (0x10, 0xffcb9843d60f6159c9db58835c926644),
   (0x20, 0xff973b41fa98c081472e6896dfb254c0),
   (0x40, 0xff2ea16466c96a3843ec78b326b52861),
   (0x80, 0xfe5dee046a99a2a811c461f1969c3053),
   (0x100, 0xfcbe86c7900a88aedcffc83b479aa3a4),
   (0x200, 0xf987a7253ac413176f2b074cf7815e54),
   (0x400, 0xf3392b0822b70005940c7a398e4b70f3),
   (0x800, 0xe7159475a2c29b7443b29c7fa6e889d9),
   (0x1000, 0xd097f3bdfd2022b8845ad8f792aa5825),
   (0x2000, 0xa9f746462d870fdf8a65dc1f90e061e5),
   (0x4000, 0x70d869a156d2a1b890bb3df62baf32f7),
   (0x8000, 0x31be135f97d08fd981231505542fcfa6),
   (0x10000, 0x9aa508b5b7a84e1c677de54f3e99bc9),
   (0x20000, 0x5d6af8dedb81196699c329225ee604),
   (0x40000, 0x2216e584f5fa1ea926041bedfe98),
   (0x80000, 0x48a170391f7dc42444e8fa2)]

/-- `TickMath.getSqrtPriceAtTick(tick)`; `none` is the `InvalidTick` revert.

    1. Revert if `|tick| > MAX_TICK`.
    2. Start from `2^128`, or the bit-0 factor if `|tick|` is odd.
    3. For each further set bit, `price = (price * factor) >> 128`. (The products stay below `2^256`,
       so the `unchecked` multiplication never wraps.)
    4. If `tick > 0`, invert: `price = type(uint256).max / price`.
    5. Round up from Q128.128 to Q64.96: `(price + 2^32 − 1) >> 32`. -/
def getSqrtPriceAtTick (tick : Int) : Option Nat :=
  let absTick := tick.natAbs
  if MAX_TICK < absTick then none
  else
    let start := if absTick % 2 = 1 then 0xfffcb933bd6fad37aa2d162d1a594001 else 2 ^ 128
    let price := tickFactors.foldl
      (fun price (bit, factor) => if absTick &&& bit ≠ 0 then price * factor / 2 ^ 128 else price)
      start
    let price := if 0 < tick then (2 ^ 256 - 1) / price else price
    some ((price + (2 ^ 32 - 1)) / 2 ^ 32)

end SwapAndAddFV
