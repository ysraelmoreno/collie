#!/usr/bin/env bash
# Check of ONE task: runs only the tests the task names (paths or -k expression).
# pytest exits 5 when it collects no test, so "nothing ran" fails too.
# Usage: scripts/check-feature.sh <caminho ou -k expr>...  e.g. scripts/check-feature.sh tests/test_soma.py
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -gt 0 ] || { echo "uso: scripts/check-feature.sh <teste>" >&2; exit 2; }
python3 -P -m pytest -q "$@"
