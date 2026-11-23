#!/usr/bin/env bash
# Check of ONE task: runs only the test files the task names (npm test -- <padrão>, for jest or vitest).
# jest and vitest exit non-zero when no test matches, so "nothing ran" fails too.
# Usage: scripts/check-feature.sh <padrão> [<padrão>...]  e.g. scripts/check-feature.sh src/soma
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -gt 0 ] || { echo "uso: scripts/check-feature.sh <padrão de arquivo de teste>" >&2; exit 2; }
npm test -- "$@"
