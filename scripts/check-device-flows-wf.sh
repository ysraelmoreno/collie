#!/usr/bin/env bash
# Checks of the device-flows wave f (specs wf1..wf3): scripts/check-device-flows-wf.sh wf1|wf2|wf3
# Each check first requires its suite to exist (a --filter that matches no test passes by itself), then a minimum test count.
set -euo pipefail
cd "$(dirname "$0")/.."
ID="${1:?wf1|wf2|wf3}"
suite() { grep -rq "struct $1" Tests/CollieDaemonKitTests || { echo "falta a suíte $1 (spec ${ID})" >&2; exit 1; }; }
need() { grep -q "$1" "$2" 2>/dev/null || { echo "falta '$1' em $2 (spec ${ID})" >&2; exit 1; }; }
swift_min() {
  local suite=$1 min=$2; shift 2
  local out; out=$(swift test --disable-sandbox --skip MemoryEventEmissionTests --filter "$suite" "$@" 2>&1) || { echo "$out" | tail -40 >&2; exit 1; }
  local n; n=$(echo "$out" | sed -nE 's/.*Test run with ([0-9]+) tests.*passed.*/\1/p' | tail -1)
  [ "${n:-0}" -ge "$min" ] || { echo "$suite: ${n:-0} testes, a spec pede pelo menos $min" >&2; exit 1; }
}
D=Sources/CollieDaemonKit/Devices
case "$ID" in
  wf1) suite FlowGuardTests; grep -rq '"guard"' $D || { echo 'falta o argumento "guard" em Devices (spec wf1)' >&2; exit 1; }
       swift_min FlowGuardTests 10 --filter FlowClassifierTests --filter FlowClassifierServiceTests --filter FlowClassifierFailClosedTests --filter FlowDestructiveTests --filter FlowRunnerTests --filter FlowTapPinTests ;;
  wf2) suite FlowGuardRefTests
       ! grep -rq "checkPin" Sources || { echo "checkPin ainda existe (spec wf2)" >&2; exit 1; }
       ! grep -q "var pin" $D/FlowRunner.swift || { echo "FlowPlan.Step.pin ainda existe (spec wf2)" >&2; exit 1; }
       swift_min FlowGuardRefTests 7 --filter FlowGuardTests --filter FlowClassifierTests --filter FlowDestructiveTests --filter FlowRunnerTests ;;
  wf3) suite FlowGuardEdgeTests
       swift_min FlowGuardEdgeTests 5 --filter FlowGuardTests --filter FlowGuardRefTests --filter FlowMaskFreshnessTests --filter FlowClassifierFailClosedTests ;;
  *) echo "tarefa desconhecida: $ID" >&2; exit 2 ;;
esac
