#!/usr/bin/env bash
# Gate of the project: collie-work.json "gate": "bash scripts/gate.sh # pytest.ini tox.ini".
# Guarded (the loop's judge refuses a try that touches a file the gate's text names, by substring): this script and the pure
# runner configs after the `#`. Only inspected (never named in the gate's text, so a task may add a dependency or a fixture):
#   conftest.py (any folder), pyproject.toml, pytest.ini, setup.cfg, tox.ini
# this script fails when one of them, in any folder git sees, forces success or is a symlink.
# Limit: the gate does not see binaries in ignored folders such as .venv (git diff never lists them).
set -euo pipefail
cd "$(dirname "$0")/.."
# a pytest.py or pytest/ at the root would shadow the real pytest (a new file: the judge never sees it); -P below also keeps
# the root off sys.path where Python has it (3.11+)
for f in pytest.py pytest; do
  if [ -e "$f" ] || [ -L "$f" ]; then echo "gate: $f na raiz troca o pytest de verdade; tire-o" >&2; exit 1; fi
done
# ponytail: plain regex over single lines, not a parser. Not caught (the reviewer's to catch): an assignment split over
# several lines, ExitCode(0), sys.exit(0), a sitecustomize.py, a config that forces success some other way (addopts = -p plugin).
# forced <ERE of config basenames>: looks only at what git sees (tracked files plus untracked ones not ignored, so never venv/,
# .tox/, node_modules/ or site-packages that .gitignore leaves out), one list for the links and for the grep. A link named like
# a runner config, or a link to a folder (its files are out of the judge's sight), fails with its own message; any other link
# (CLAUDE.md -> AGENTS.md) is not the runner's business. awk gets each config as ./path (never an option nor an awk assignment)
# and tests the line's text alone, so a folder named `a:1:#x/` cannot pass a forced line off as a comment. A comment is `//`
# in .js/.ts, `#` in .py/.ini/.toml/.cfg, nothing in .json. A git or awk error fails the gate.
re='passWithNoTests"?[[:space:]]*[:=][[:space:]]*true|testFailureExitCode"?[[:space:]]*[:=][[:space:]]*0([^0-9]|$)|--co([^[:alnum:]_-]|$)|--collect-only|_exit\(0\)|exitstatus[[:space:]]*=[[:space:]]*(0([^0-9]|$)|False|\(|(pytest\.)?ExitCode\.OK)'
forced() {
  local names=$1 f base links="" hit="" cfgs=()
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "gate: fora de um repositório git; o gate olha o que o git vê" >&2; exit 1; }
  while IFS= read -r -d '' f; do
    base=${f##*/}
    if [ -L "$f" ]; then
      if [[ $base =~ $names ]]; then links+="link simbólico em arquivo de config do runner: $f"$'\n'
      elif [ -d "$f" ]; then links+="link simbólico para pasta: $f"$'\n'; fi
    elif [ -f "$f" ] && [[ $base =~ $names ]]; then cfgs+=("./$f"); fi
  done < <(git ls-files -z -c -o --exclude-standard)
  [ -z "$links" ] || { printf '%s' "$links" >&2; echo "gate: troque o link por uma cópia (o alvo fica fora da vista do juiz)" >&2; exit 1; }
  [ ${#cfgs[@]} -gt 0 ] || return 0
  hit=$(env RE="$re" awk 'FNR == 1 { cm = (FILENAME ~ /\.[cm]?[jt]s$/) ? "^[[:space:]]*//" : ((FILENAME ~ /\.json$/) ? "" : "^[[:space:]]*#") }
    $0 ~ ENVIRON["RE"] && !(cm != "" && $0 ~ cm) { print substr(FILENAME, 3) ":" FNR ": " $0 }' "${cfgs[@]}") \
    || { echo "gate: não deu para ler as configs do runner" >&2; exit 1; }
  [ -z "$hit" ] || { printf '%s\n' "$hit" >&2; echo "gate: a config do runner força sucesso; tire a opção acima" >&2; exit 1; }
}
forced '^(conftest\.py|pyproject\.toml|pytest\.ini|setup\.cfg|tox\.ini)$'
# -P (Python 3.11+): the current folder is not put on sys.path; older Python has no -P, the root check above covers it
if python3 -I -c 'import sys; sys.exit(sys.version_info < (3, 11))'; then exec python3 -P -m pytest -q; fi
exec python3 -m pytest -q
