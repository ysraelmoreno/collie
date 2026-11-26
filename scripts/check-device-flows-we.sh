#!/usr/bin/env bash
# Checks of the device-flows wave e (specs we1, we2): scripts/check-device-flows-we.sh we1|we2
# Each check first requires what its task delivers (a --filter that matches no test passes by itself), then runs the tests and
# requires a minimum count, so a thin suite does not pass.
set -euo pipefail
cd "$(dirname "$0")/.."
D=Sources/CollieDaemonKit/Devices
need() { grep -q "$1" "$2" 2>/dev/null || { echo "falta '$1' em $2 (spec ${ID})" >&2; exit 1; }; }
# swift_min <Suite> <min tests> [more --filter args...]
swift_min() {
  local suite=$1 min=$2; shift 2
  local out; out=$(swift test --disable-sandbox --skip MemoryEventEmissionTests --filter "$suite" "$@" 2>&1) || { echo "$out" | tail -40 >&2; exit 1; }
  local n; n=$(echo "$out" | sed -nE 's/.*Test run with ([0-9]+) tests.*passed.*/\1/p' | tail -1)
  [ "${n:-0}" -ge "$min" ] || { echo "$suite: ${n:-0} testes, a spec pede pelo menos $min" >&2; exit 1; }
}
# py_min <dir> <pattern> <min tests>
py_min() {
  local out; out=$(python3 -m unittest discover -s "$1" -p "$2" 2>&1) || { echo "$out" | tail -40 >&2; exit 1; }
  local n; n=$(echo "$out" | sed -nE 's/^Ran ([0-9]+) tests?.*/\1/p' | tail -1)
  [ "${n:-0}" -ge "$3" ] || { echo "$2: ${n:-0} testes, a spec pede pelo menos $3" >&2; exit 1; }
}
ID="${1:?we1|we2}"
suite() { grep -rq "struct $1" Tests/CollieDaemonKitTests || { echo "falta a suíte $1 (spec ${ID})" >&2; exit 1; }; }
case "$ID" in
  we1) suite FlowTapPinTests
       swift_min FlowTapPinTests 7 --filter FlowClassifierFailClosedTests --filter FlowClassifierServiceTests --filter FlowClassifierTests --filter FlowDestructiveTests --filter FlowRunnerTests ;;
  we2) suite FlowRootFalsePositiveTests
       swift_min FlowRootFalsePositiveTests 5 --filter FlowMaskFreshnessTests --filter FlowTapPinTests --filter FlowClassifierFailClosedTests ;;
  *) echo "tarefa desconhecida: $ID" >&2; exit 2 ;;
esac
