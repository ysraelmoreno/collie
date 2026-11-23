#!/usr/bin/env bash
# Gate of the project: collie-work.json "gate": "bash scripts/gate.sh". The loop's judge guards this file (the gate's text
# cites it), not the config files that govern the runner, so this script runs the runner directly (never through a script an
# agent can edit, like the "test" of package.json) and fails when one of these files forces success:
#   package.json, jest.config.*, vitest.config.*, vite.config.*, vitest.workspace.*
set -euo pipefail
cd "$(dirname "$0")/.."
# forced <find -name tests>: a config file whose setting makes the runner pass with no test. find hands the paths to
# grep itself (-exec +), so a path with a space or a glob character is never split by the shell.
# ponytail: plain grep, not a parser; a config that forces success some other way is the reviewer's to catch.
forced() {
  local hit
  hit=$(find . \( -name .git -o -name node_modules -o -name .venv -o -name .build \) -prune -o -type f \( "$@" \) \
        -exec grep -EnH 'passWithNoTests|exitstatus *= *0' {} + 2>/dev/null) || true
  [ -z "$hit" ] || { printf '%s\n' "$hit" >&2; echo "gate: a config do runner força sucesso; tire a opção acima" >&2; exit 1; }
}
forced -name package.json -o -name 'jest.config.*' -o -name 'vitest.config.*' -o -name 'vite.config.*' -o -name 'vitest.workspace.*'
# vitest when package.json lists it, else jest: the same choice as scripts/factory-detect.sh (tools.node.testRunner)
if grep -q '"vitest"' package.json; then exec npx vitest run; else exec npx jest; fi
