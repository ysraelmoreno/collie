#!/usr/bin/env bash
# Gate of the project: collie-work.json "gate": "bash scripts/gate.sh # package.json jest.config.js vitest.config.ts".
# The loop's judge guards every file the gate's text names (substring), so the gate's text cites this script and the config
# files at the root that govern the runner; this script also fails when one of them (in any folder) forces success:
#   package.json, jest.config.*, vitest.config.*, vite.config.*, vitest.workspace.*
# Limit: the gate does not see binaries in ignored folders such as node_modules/.bin (git diff never lists them).
set -euo pipefail
cd "$(dirname "$0")/.."
# forced <find -name tests>: any symlink outside the pruned folders (a linked config or a linked folder, e.g.
# tests2 -> node_modules/x, has its target out of the judge's sight) or a config line that makes the runner pass with no test
# or with failures. find hands the paths to awk itself (-exec +), so a path with a space, a glob character or a ':' is never
# split by the shell, and awk tests the line's text alone (never the "path:line:" prefix), so a folder named `a:1:#x/`
# cannot pass a forced line off as a comment. Comment lines (# or //) are not settings. A find/awk error fails the gate.
# ponytail: plain regex, not a parser; a config that forces success some other way (require of another file) is the reviewer's to catch.
re='passWithNoTests"?[[:space:]]*[:=][[:space:]]*true|testFailureExitCode|--co([^[:alnum:]_-]|$)|--collect-only|ExitCode\.OK|_exit\(0\)|exitstatus[[:space:]]*=[[:space:]]*0'
forced() {
  local skip=( \( -name .git -o -name node_modules -o -name .venv -o -name .build \) -prune -o ) hit
  hit=$( find . "${skip[@]}" -type l -print | sed 's/$/: link simbólico/' &&
         find . "${skip[@]}" -type f \( "$@" \) -exec env RE="$re" awk \
           '$0 ~ ENVIRON["RE"] && $0 !~ /^[[:space:]]*(#|\/\/)/ { print FILENAME ":" FNR ": " $0 }' {} + ) \
    || { echo "gate: não deu para ler as configs do runner" >&2; exit 1; }
  [ -z "$hit" ] || { printf '%s\n' "$hit" >&2; echo "gate: a config do runner força sucesso; tire a opção acima" >&2; exit 1; }
}
forced -name package.json -o -name 'jest.config.*' -o -name 'vitest.config.*' -o -name 'vite.config.*' -o -name 'vitest.workspace.*'
# the runner is fixed here by /collie:factory init (tools.node.testRunner): `npx --no-install vitest run` or
# `npx --no-install jest`. Never chosen at run time from package.json (an agent can edit it), never a download.
exec npx --no-install vitest run
