#!/usr/bin/env bash
# Checks of the device-flows wave c (docs/superpowers/specs/device-flows-b/c*.md): scripts/check-device-flows-c.sh c1|c2|c3
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
ID="${1:?c1|c2|c3}"
suite() { grep -rq "struct $1" Tests/CollieDaemonKitTests || { echo "falta a suíte $1 (spec ${ID})" >&2; exit 1; }; }
case "$ID" in
  c1) suite FlowClassifierServiceTests
      swift_min FlowClassifierServiceTests 8 --filter FlowClassifierTests --filter FlowDestructiveTests --filter FlowRunnerTests ;;
  c2) suite FlowCancelTests
      swift_min FlowCancelTests 6 --filter FlowRunnerWaveBTests --filter FlowLogHardeningTests --filter FlowActionLogTests ;;
  c3) suite FlowMaskRaceTests
      swift_min FlowMaskRaceTests 6 --filter FlowSecureTests --filter FlowMinorsTests --filter FlowActionRecordingTests ;;
  *) echo "tarefa desconhecida: $ID" >&2; exit 2 ;;
esac
