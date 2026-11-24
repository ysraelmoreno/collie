#!/usr/bin/env bash
# Check of ONE task: runs only the tests the task names (paths or -k expression).
# pytest exits 5 when it collects no test, so "nothing ran" fails too.
# Usage: scripts/check-feature.sh <caminho ou -k expr>...  e.g. scripts/check-feature.sh tests/test_soma.py
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -gt 0 ] || { echo "uso: scripts/check-feature.sh <teste>" >&2; exit 2; }
# the root never goes on sys.path (a pluggy.py or _pytest/ there cannot stand in) and the user's site is never read: -I in
# every Python. The same line as scripts/gate.sh
exec python3 -I -m pytest -q "$@"
