#!/usr/bin/env bash
# Check of ONE task: runs only the tests the task names (swift test --filter) and fails when none ran.
# Usage: scripts/check-feature.sh <filtro> [<filtro>...]  e.g. scripts/check-feature.sh SomaTests
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -gt 0 ] || { echo "uso: scripts/check-feature.sh <filtro de teste>" >&2; exit 2; }
args=(); for f in "$@"; do args+=(--filter "$f"); done
out=$(swift test "${args[@]}" 2>&1) || { printf '%s\n' "$out"; exit 1; }
printf '%s\n' "$out"
# compiling is not a check: some test must have run (XCTest or Swift Testing)
printf '%s\n' "$out" | grep -Eq 'Executed [1-9][0-9]* test|Test run with [1-9][0-9]* test' \
  || { echo "nenhum teste rodou com: $*" >&2; exit 1; }
