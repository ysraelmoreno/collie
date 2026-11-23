#!/usr/bin/env bash
# Gate of the project: collie-work.json "gate": "bash scripts/gate.sh # jest.config.js vitest.config.ts vite.config.ts".
# Guarded (the loop's judge refuses a try that touches a file the gate's text names, by substring): this script and the pure
# runner configs after the `#`. Only inspected (never named in the gate's text, so a task may add a dependency or a script):
#   package.json, jest.config.*, vitest.config.*, vite.config.*, vitest.workspace.*
# this script fails when one of them, in any folder git sees, forces success or is a symlink.
# Limit: the gate does not see binaries in ignored folders such as node_modules/.bin (git diff never lists them).
set -euo pipefail
cd "$(dirname "$0")/.."
# ponytail: plain regex over single lines, not a parser. Not caught (the reviewer's to catch): an assignment split over
# several lines, ExitCode(0), sys.exit(0), a sitecustomize.py, a config that forces success some other way (require("./cfg.json")).
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
forced '^(package\.json|(jest|vitest|vite)\.config\..*|vitest\.workspace\..*)$'
# the runner is fixed here by /collie:factory init (tools.node.testRunner): `npx --no-install vitest run` or
# `npx --no-install jest`. Never chosen at run time from package.json (an agent can edit it), never a download.
exec npx --no-install vitest run
