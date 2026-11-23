#!/usr/bin/env bash
# Gate of the project: collie-work.json "gate": "bash scripts/gate.sh # pytest.ini pyproject.toml setup.cfg conftest.py tox.ini".
# The loop's judge guards every file the gate's text names (substring), so the gate's text cites this script and the config
# files at the root that govern the runner; this script also fails when one of them (in any folder) forces success:
#   conftest.py (any folder), pyproject.toml, pytest.ini, setup.cfg, tox.ini
# Limit: the gate does not see binaries in ignored folders such as .venv (git diff never lists them).
set -euo pipefail
cd "$(dirname "$0")/.."
# a pytest.py or pytest/ at the root would shadow the real pytest (a new file: the judge never sees it); -P below also keeps
# the root off sys.path
for f in pytest.py pytest; do
  if [ -e "$f" ] || [ -L "$f" ]; then echo "gate: $f na raiz troca o pytest de verdade; tire-o" >&2; exit 1; fi
done
# forced <find -name tests>: any symlink outside the pruned folders (a linked config or a linked folder, e.g.
# tests2 -> node_modules/x, has its target out of the judge's sight) or a config line that makes the runner pass with no test
# or with failures. find hands the paths to awk itself (-exec +), so a path with a space, a glob character or a ':' is never
# split by the shell, and awk tests the line's text alone (never the "path:line:" prefix), so a folder named `a:1:#x/`
# cannot pass a forced line off as a comment. Comment lines (# or //) are not settings. A find/awk error fails the gate.
# ponytail: plain regex, not a parser; a config that forces success some other way (addopts = -p plugin) is the reviewer's to catch.
re='passWithNoTests"?[[:space:]]*[:=][[:space:]]*true|testFailureExitCode|--co([^[:alnum:]_-]|$)|--collect-only|ExitCode\.OK|_exit\(0\)|exitstatus[[:space:]]*=[[:space:]]*0'
forced() {
  local skip=( \( -name .git -o -name node_modules -o -name .venv -o -name .build \) -prune -o ) hit
  hit=$( find . "${skip[@]}" -type l -print | sed 's/$/: link simbólico/' &&
         find . "${skip[@]}" -type f \( "$@" \) -exec env RE="$re" awk \
           '$0 ~ ENVIRON["RE"] && $0 !~ /^[[:space:]]*(#|\/\/)/ { print FILENAME ":" FNR ": " $0 }' {} + ) \
    || { echo "gate: não deu para ler as configs do runner" >&2; exit 1; }
  [ -z "$hit" ] || { printf '%s\n' "$hit" >&2; echo "gate: a config do runner força sucesso; tire a opção acima" >&2; exit 1; }
}
forced -name conftest.py -o -name pyproject.toml -o -name pytest.ini -o -name setup.cfg -o -name tox.ini
# -P (Python 3.11+): the current folder is not put on sys.path, so no file of the project stands in for pytest
exec python3 -P -m pytest -q
