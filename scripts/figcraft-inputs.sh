#!/bin/bash
# Prints the `inputs` of Resources/figcraft-engine.json: the sha256 of one "<sha256>  <path>" line per engine build
# input, paths sorted (LC_ALL=C). Read-only. Checked by figcraft.yml and FigcraftPinInputsTests.
# Changing any input (a comment in figcraft.yml included) needs -c<N+1> in the pin and this value as `inputs`.
set -euo pipefail
shopt -s failglob
cd "$(dirname "$0")/.."
export LC_ALL=C
printf '%s\n' scripts/build-figcraft.sh scripts/package-figcraft.sh scripts/figcraft-inputs.sh \
  .github/workflows/figcraft.yml patches/figcraft/*.patch \
  | sort | while IFS= read -r f; do shasum -a 256 "$f"; done | shasum -a 256 | cut -d' ' -f1
