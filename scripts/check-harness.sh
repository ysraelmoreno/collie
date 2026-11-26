#!/usr/bin/env bash
# Checks of the harness tasks (docs/superpowers/specs/harness/h*.md): scripts/check-harness.sh h1|h2|h3
# Each check first requires its suite to exist (a --filter that matches no test passes by itself), then a minimum test count.
set -euo pipefail
cd "$(dirname "$0")/.."
ID="${1:?h1|h2|h3}"
suite() { grep -rq "struct $1" Tests || { echo "falta a suíte $1 (spec ${ID})" >&2; exit 1; }; }
swift_min() {
  local suite=$1 min=$2; shift 2
  local out; out=$(swift test --disable-sandbox --skip MemoryEventEmissionTests --filter "$suite" "$@" 2>&1) || { echo "$out" | tail -40 >&2; exit 1; }
  local n; n=$(echo "$out" | sed -nE 's/.*Test run with ([0-9]+) tests.*passed.*/\1/p' | tail -1)
  [ "${n:-0}" -ge "$min" ] || { echo "$suite: ${n:-0} testes, a spec pede pelo menos $min" >&2; exit 1; }
}
case "$ID" in
  h1) suite HarnessConfigTests
      swift_min HarnessConfigTests 16 --filter ProjectWorkConfigTests --filter FactoryProfileTests --filter WorkConfigTamperTests ;;
  h2) suite HarnessMatcherTests
      swift_min HarnessMatcherTests 20 --filter HarnessConfigTests ;;
  h3) suite HarnessCommandTests
      grep -q "harness.explain" Sources/CollieProtocol/Commands.swift || { echo "falta harness.explain em Commands.swift (spec h3)" >&2; exit 1; }
      swift_min HarnessCommandTests 8 --filter ProjectWorkConfigTests --filter HarnessConfigTests --filter HarnessMatcherTests --filter CommandsTests ;;
  *) echo "tarefa desconhecida: $ID" >&2; exit 2 ;;
esac
