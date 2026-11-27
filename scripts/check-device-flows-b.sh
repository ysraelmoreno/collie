#!/usr/bin/env bash
# Checks of the device-flows wave b (docs/superpowers/specs/device-flows-b/*.md): scripts/check-device-flows-b.sh b1|b2|b3|b4|b5
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
ID="${1:?b1|b2|b3|b4|b5}"
case "$ID" in
  b1) need "password: " Sources/CollieDevice/AXeTree.swift
      grep -rq "struct FlowSecureTests" Tests/CollieDaemonKitTests || { echo "falta a suíte FlowSecureTests (spec b1)" >&2; exit 1; }
      swift_min FlowSecureTests 6 --filter FlowActionRecordingTests --filter FlowActionLogTests ;;
  b2) need "O_NOFOLLOW" $D/FlowActionLog.swift
      grep -rq "struct FlowLogHardeningTests" Tests/CollieDaemonKitTests || { echo "falta a suíte FlowLogHardeningTests (spec b2)" >&2; exit 1; }
      swift_min FlowLogHardeningTests 7 --filter FlowActionLogTests --filter FlowActionRecordingTests ;;
  b3) grep -rq "struct FlowClassifierTests" Tests/CollieDaemonKitTests || { echo "falta a suíte FlowClassifierTests (spec b3)" >&2; exit 1; }
      swift_min FlowClassifierTests 8 --filter FlowDestructiveTests --filter FlowRunnerTests ;;
  b4) grep -rq "struct FlowRunnerWaveBTests" Tests/CollieDaemonKitTests || { echo "falta a suíte FlowRunnerWaveBTests (spec b4)" >&2; exit 1; }
      need "settle" $D/FlowRunner.swift
      swift_min FlowRunnerWaveBTests 7 --filter FlowRunnerTests --filter FlowDestructiveTests --filter FlowActionRecordingTests ;;
  b5) grep -rq "struct FlowMinorsTests" Tests/CollieDaemonKitTests || { echo "falta a suíte FlowMinorsTests (spec b5)" >&2; exit 1; }
      swift_min FlowMinorsTests 4 --filter DeviceCommandTests ;;
  *) echo "tarefa desconhecida: $ID" >&2; exit 2 ;;
esac
