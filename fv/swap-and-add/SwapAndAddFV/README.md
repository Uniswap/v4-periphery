# SwapAndAddFV

Lean 4 proofs for `SwapAndAddMath`. What is proved, and under which assumptions, is in
[`../SPEC.md`](../SPEC.md).

## Layout

| File                               | Contents                                                                                |
| ---------------------------------- | --------------------------------------------------------------------------------------- |
| `SwapAndAddFV/V4Math.lean`         | Models of the v4-core arithmetic (SPEC D1–D4). No Mathlib dependency.                   |
| `SwapAndAddFV/SwapAndAddMath.lean` | Models of `SwapAndAddMath`, `_planLiquidity` sizing, and the `_trim` cap. No Mathlib.   |
| `SwapAndAddFV/Assumptions.lean`    | SPEC A1 and A2 as a `WellFormed` predicate.                                             |
| `SwapAndAddFV/TickMath.lean`       | Model of `TickMath.getSqrtPriceAtTick` (SPEC D6). No Mathlib.                           |
| `SwapAndAddFV/TickMathFacts.lean`  | Reference values the TickMath model reproduces, kernel-checked.                         |
| `SwapAndAddFV/Trim.lean`           | P2: the trim frees enough of the shortfall token, and no more.                          |
| `SwapAndAddFV/Sizing.lean`         | P1, P3, P4a, P5a–c, P7: mint amounts, fees, the rate and reference value, the trim cap. |
| `Vectors.lean`                     | Generates `../vectors/*.json` from the models.                                          |

## Running the checks

All checks, in order, with one command:

```sh
fv/swap-and-add/check.sh
```

It needs [elan](https://github.com/leanprover/elan) (`brew install elan-init`), Foundry, and the
repo set up for `forge test` (`git submodule update --init --recursive`, then
`yarn install --frozen-lockfile --ignore-scripts` in `lib/universal-router`). The steps it runs:

| Step                                                         | Run from                       | Checks                                                                                                    |
| ------------------------------------------------------------ | ------------------------------ | --------------------------------------------------------------------------------------------------------- |
| `lake exe cache get`                                         | `fv/swap-and-add/SwapAndAddFV` | Downloads prebuilt Mathlib (otherwise `lake build` compiles it, hours).                                   |
| `lake build --wfail`                                         | `fv/swap-and-add/SwapAndAddFV` | Every proof checks. Any warning fails, including a proof left as `sorry` (plain `lake build` only warns). |
| `lake exe vectors`, then compare with the committed files    | `fv/swap-and-add/SwapAndAddFV` | The committed test vectors are what the current models generate. Writes to `../vectors/`.                 |
| `forge test --match-path test/SwapAndAddMathLeanModel.t.sol` | repo root                      | The models compute exactly what the Solidity computes on every vector.                                    |

`lake` commands must run from `fv/swap-and-add/SwapAndAddFV`, where the Lean project's
`lakefile.toml` and `lean-toolchain` are. `check.sh` changes into the right directory for each step,
so it can be run from anywhere.

The proofs are about the Lean models, so the last two steps are what tie them to the code. After
changing a model or the Solidity, run `lake exe vectors`, review the diff in `../vectors/`, and
commit it with the change.

## CI

- `.github/workflows/fv.yml` builds the proofs with `--wfail` and checks the committed vectors are
  up to date. It runs on pushes to `main` and on pull requests touching `fv/swap-and-add/`,
  `SwapAndAddMath.sol`, the vector test, or `lib/v4-core`.
- The existing Forge Tests workflow (`test.yml`) runs `test/SwapAndAddMathLeanModel.t.sol` with the
  rest of the suite, so every PR checks the vectors against the Solidity.
