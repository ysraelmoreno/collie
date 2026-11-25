#!/usr/bin/env bash
# Gate of the project: collie-work.json "gate": "bash scripts/gate.sh # jest.config.js vitest.config.ts".
# Guarded (the loop's judge refuses a try that touches a file the gate's text names, by substring): this script and the pure
# runner configs after the `#`. Only inspected (never named in the gate's text, so a task may add a dependency, a script or a
# Vite build option): package.json, jest.config.*, vitest.config.*, vite.config.*, vitest.workspace.*
# this script fails when one of them forces success or is a symlink, in any folder git lists: tracked, untracked, and ignored
# too (.gitignore or .git/info/exclude), except inside a venv (pyvenv.cfg), node_modules/, .tox/ and site-packages/.
# Limit: the gate does not see binaries in ignored folders such as node_modules/.bin (git diff never lists them); an ignored
# file counts only by its config name. Outside a git repository, or without git, the gate fails on purpose.
set -euo pipefail
cd "$(dirname "$0")/.."
# ponytail: plain regex over single lines, not a parser. Not caught (the reviewer's to catch): an assignment split over
# several lines, ExitCode(0), sys.exit(0), a sitecustomize.py, a config that forces success some other way (require("./cfg.json")).
# forced <ERE of config basenames> <pathspec>...: ONE list for the links and for the grep: what git sees (tracked files plus
# untracked ones not ignored) and, among the ignored files (the agent decides what is ignored), those matching the pathspecs;
# every untracked file, ignored or not (C2), pruned of a venv (a folder with pyvenv.cfg), node_modules/, .tox/ and site-packages/. A link named like a runner config fails;
# a link to a folder fails only when its target (pwd -P) leaves the repository (.claude/skills -> ../.agents/skills passes: git
# lists the target's files where they are); any other link (CLAUDE.md -> AGENTS.md) is not the runner's business. awk gets each
# config as ./path (never an option nor an awk assignment) and tests the line's text alone, so a folder named `a:1:#x/` cannot
# pass a forced line off as a comment. A comment is a `//` line in .js/.ts, a `#` or `;` line in .ini/.cfg (C2: a `#`
# later in the line is the value's: `addopts = -q # --co` is forced) and what follows a `#` out of quotes in .py/.toml; .json has none. This block is the same in every model's gate.sh
# (FactoryModelsTests compares them). No git, outside a repository, a git, mktemp or awk error: the gate fails.
re='passWithNoTests"?[[:space:]]*[:=][[:space:]]*true|testFailureExitCode"?[[:space:]]*[:=][[:space:]]*0([^0-9]|$)|--co([^[:alnum:]_-]|$)|--collect-only|_exit\(0\)|exitstatus[[:space:]]*=[[:space:]]*(0([^0-9]|$)|False|\(|(pytest\.)?ExitCode\.OK)'
lst="" unt="" ign=""
forced() {
  local names=$1 pruned='/(node_modules|\.tox|site-packages)/' f p skip root links="" hit="" cfgs=() venvs=()
  shift
  command -v git >/dev/null 2>&1 || { echo "gate: git não encontrado no PATH; o gate olha o que o git vê" >&2; exit 1; }
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "gate: fora de um repositório git; o gate olha o que o git vê" >&2; exit 1; }
  root=$(pwd -P)
  trap 'rm -f "$lst" "$unt" "$ign"' EXIT
  lst=$(mktemp) && unt=$(mktemp) && ign=$(mktemp) || { echo "gate: mktemp falhou" >&2; exit 1; }
  git ls-files -z -c > "$lst" || { echo "gate: git ls-files falhou" >&2; exit 1; }
  git ls-files -z -o --exclude-standard > "$unt" || { echo "gate: git ls-files falhou" >&2; exit 1; }
  git ls-files -z -o -i --exclude-standard -- "$@" '*pyvenv.cfg' > "$ign" || { echo "gate: git ls-files falhou" >&2; exit 1; }
  cat "$ign" >> "$unt" || { echo "gate: git ls-files falhou" >&2; exit 1; }
  see() {
    local base=${1##*/} t
    if [ -L "$1" ]; then
      if [[ $base =~ $names ]]; then links+="link simbólico em arquivo de config do runner: $1"$'\n'
      elif [ -d "$1" ]; then
        t=$(CDPATH= cd -- "$1" 2>/dev/null && pwd -P) || t=/
        [[ $t == "$root" || $t == "$root"/* ]] || links+="link simbólico para pasta fora do repositório: $1"$'\n'
      fi
    elif [ -f "$1" ] && [[ $base =~ $names ]]; then cfgs+=("./$1"); fi
  }
  while IFS= read -r -d '' f; do see "$f"; done < "$lst"
  while IFS= read -r -d '' f; do
    if [[ ${f##*/} == pyvenv.cfg && $f == */* ]]; then venvs+=("${f%pyvenv.cfg}"); fi
  done < "$unt"
  while IFS= read -r -d '' f; do
    [[ /$f =~ $pruned ]] && continue
    skip=""; for p in ${venvs[@]+"${venvs[@]}"}; do [[ $f == "$p"* ]] && { skip=1; break; }; done
    [ -n "$skip" ] || see "$f"
  done < "$unt"
  rm -f "$lst" "$unt" "$ign"; trap - EXIT
  [ -z "$links" ] || { printf '%s' "$links" >&2; echo "gate: troque o link por uma cópia (o alvo fica fora da vista do juiz)" >&2; exit 1; }
  [ ${#cfgs[@]} -gt 0 ] || return 0
  hit=$(env RE="$re" awk 'FNR == 1 { js = (FILENAME ~ /\.[cm]?[jt]s$/); ini = (FILENAME ~ /\.(ini|cfg)$/); hash = !js && !ini && FILENAME !~ /\.json$/ }
    { s = $0
      if (ini && s ~ /^[[:space:]]*[#;]/) s = ""
      if (hash) { q = ""
        for (i = 1; i <= length(s); i++) { c = substr(s, i, 1)
          if (q != "") { if (c == q) q = "" } else if (c == "\047" || c == "\"") q = c; else if (c == "#") { s = substr(s, 1, i - 1); break } } }
      if (s ~ ENVIRON["RE"] && !(js && s ~ /^[[:space:]]*\/\//)) print substr(FILENAME, 3) ":" FNR ": " $0 }' "${cfgs[@]}") \
    || { echo "gate: não deu para ler as configs do runner" >&2; exit 1; }
  [ -z "$hit" ] || { printf '%s\n' "$hit" >&2; echo "gate: a config do runner força sucesso; tire a opção acima" >&2; exit 1; }
}
forced '^(package\.json|(jest|vitest|vite)\.config\..*|vitest\.workspace\..*)$' '*package.json' '*jest.config.*' '*vitest.config.*' '*vite.config.*' '*vitest.workspace.*'
# the runner is fixed here by /collie:factory init (tools.node.testRunner): `npx --no-install vitest run` or
# `npx --no-install jest`. Never chosen at run time from package.json (an agent can edit it), never a download.
exec npx --no-install vitest run
