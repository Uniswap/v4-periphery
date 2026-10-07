#!/usr/bin/env bash
# Runs every SwapAndAdd formal-verification check. Requires elan and Foundry, and the repo set up
# for `forge test` (submodules, plus `yarn install --ignore-scripts` in lib/universal-router).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

cd "$here/SwapAndAddFV"
lake exe cache get   # prebuilt Mathlib
lake build --wfail   # proofs; any error, warning, or `sorry` fails the build
lake exe vectors     # regenerate test vectors from the models

if [ -n "$(git -C "$repo" status --porcelain -- fv/swap-and-add/vectors)" ]; then
  echo "fv/swap-and-add/vectors differs from the committed files: the models changed."
  echo "Review and commit the regenerated vectors."
  exit 1
fi

cd "$repo"
forge test --match-path test/SwapAndAddMathLeanModel.t.sol   # models agree with the Solidity
