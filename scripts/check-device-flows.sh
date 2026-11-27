#!/usr/bin/env bash
# Checks of the device-flows tasks (docs/superpowers/specs/device-flows/*.md): scripts/check-device-flows.sh d1|d2|d3|d4|d5|d6|d7|d8|d9|d10
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
ID="${1:?d1|d2|d3|d4|d5|d6|d7|d8|d9|d10}"
case "$ID" in
  d1) need "enum ScreenSignature" $D/ScreenSignature.swift; need "sig=" $D/DeviceService.swift
      swift_min ScreenSignatureTests 6 --filter DeviceCommandTests ;;
  d2) need "struct ScreenErrors" $D/ScreenErrors.swift; need "ERROS DESDE A ÚLTIMA LEITURA" $D/DeviceService.swift
      swift_min ScreenErrorsTests 5 --filter DeviceCommandTests --filter DeviceWatchTests ;;
  d3) need "enum ScreenAccessibility" $D/ScreenAccessibility.swift; need "ACESSIBILIDADE:" $D/DeviceService.swift
      swift_min ScreenAccessibilityTests 5 --filter DeviceCommandTests ;;
  d4) need "struct FlowActionLog" $D/FlowActionLog.swift; need "device.flow" Sources/CollieProtocol/Commands.swift
      swift_min FlowActionLogTests 7 --filter DeviceCommandTests ;;
  d5) need "FlowActionLog" $D/DeviceService.swift
      grep -rq "struct FlowActionRecordingTests" Tests/CollieDaemonKitTests || { echo "falta a suíte FlowActionRecordingTests (spec d5)" >&2; exit 1; }
      swift_min FlowActionRecordingTests 5 --filter FlowActionLogTests --filter DeviceCommandTests ;;
  d6) need "struct FlowRunner" $D/FlowRunner.swift; need '"device.run"' Sources/CollieProtocol/Commands.swift
      swift_min FlowRunnerTests 7 --filter DeviceCommandTests --filter CommandsTests ;;
  d7) grep -rq "struct FlowDestructiveTests" Tests/CollieDaemonKitTests || { echo "falta a suíte FlowDestructiveTests (spec d7)" >&2; exit 1; }
      need "confirm-destructive" Sources/CollieProtocol/Commands.swift
      swift_min FlowDestructiveTests 5 --filter FlowRunnerTests ;;
  d8) need "def build_graph" Examples/apps/fluxos/store.py
      py_min Examples/apps/fluxos/tests test_store.py 8 ;;
  d9) need "def plan" Examples/apps/fluxos/planner.py; test -f Examples/apps/fluxos/collie.json || { echo "falta Examples/apps/fluxos/collie.json (spec d9)" >&2; exit 1; }
      py_min Examples/apps/fluxos/tests test_planner.py 6; py_min Examples/apps/fluxos/tests test_contract.py 4
      python3 -c "import json;d=json.load(open('Examples/apps/fluxos/collie.json'));n={c['name'] for c in d['commands']};assert {'goals','go','show','learn'}<=n,n" ;;
  d10) test -f Examples/apps/fluxos/ui/index.html || { echo "falta ui/index.html (spec d10)" >&2; exit 1; }
       need "actions.jsonl" Examples/apps/fluxos/README.md
       py_min Examples/apps/fluxos/tests test_ui.py 3 ;;
  *) echo "tarefa desconhecida: $ID" >&2; exit 2 ;;
esac
