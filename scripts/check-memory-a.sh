#!/usr/bin/env bash
# Checks of the memory wave A (docs/superpowers/specs/memory-a/*.md): scripts/check-memory-a.sh ma1|ma2|ma3|ma4
# Each check first requires its suite to exist (a --filter that matches no test passes by itself), then a minimum test count.
set -euo pipefail
cd "$(dirname "$0")/.."
ID="${1:?ma1|ma2|ma3|ma4}"
suite() { grep -rq "struct $1" Tests/CollieDaemonKitTests || { echo "falta a suíte $1 (spec ${ID})" >&2; exit 1; }; }
swift_min() {
  local suite=$1 min=$2; shift 2
  local out; out=$(swift test --disable-sandbox --skip MemoryEventEmissionTests --filter "$suite" "$@" 2>&1) || { echo "$out" | tail -40 >&2; exit 1; }
  local n; n=$(echo "$out" | sed -nE 's/.*Test run with ([0-9]+) tests.*passed.*/\1/p' | tail -1)
  [ "${n:-0}" -ge "$min" ] || { echo "$suite: ${n:-0} testes, a spec pede pelo menos $min" >&2; exit 1; }
}
case "$ID" in
  ma1) suite MemoryDedupDurableTests
       swift_min MemoryDedupDurableTests 6 --filter InjectionDedupTests --filter LifecycleInjectionTests --filter MemoryHookTests --filter PastorContextLifecycleTests ;;
  ma2) suite MemoryUseSignalTests
       swift_min MemoryUseSignalTests 5 --filter LifecycleStoreTests --filter LifecyclePassTests --filter MemoryObservabilityTests ;;
  ma3) suite LifecycleEarnedEvidenceTests
       swift_min LifecycleEarnedEvidenceTests 6 --filter LifecycleRulesTests --filter LifecyclePassTests --filter LifecycleStoreTests ;;
  ma4) suite CuratorFailureStatsTests
       swift_min CuratorFailureStatsTests 6 --filter ConsolidationTests --filter CuratorQueueTests --filter MemoryObservabilityTests ;;
  *) echo "tarefa desconhecida: $ID" >&2; exit 2 ;;
esac
