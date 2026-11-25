#!/usr/bin/env bash
# Check of ONE task: runs only the test files the task names, with the runner itself (never `npm test --`, whose script an
# agent can edit and whose "test" may chain more commands). jest and vitest exit non-zero when no test matches, so "nothing
# ran" fails too (scripts/gate.sh refuses a config with passWithNoTests).
# Usage: scripts/check-feature.sh <padrão> [<padrão>...]  e.g. scripts/check-feature.sh src/soma
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -gt 0 ] || { echo "uso: scripts/check-feature.sh <padrão de arquivo de teste>" >&2; exit 2; }
# the same runner scripts/gate.sh calls, fixed by /collie:factory init (`npx --no-install jest "$@"` for jest)
exec npx --no-install vitest run "$@"
