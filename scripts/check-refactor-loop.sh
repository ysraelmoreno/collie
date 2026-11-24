#!/usr/bin/env bash
# Checks of the refactor loop (docs/superpowers/specs/refactor/*.md): scripts/check-refactor-loop.sh r1|r2|r3
set -euo pipefail
cd "$(dirname "$0")/.."
t() { swift test --disable-sandbox --skip MemoryEventEmissionTests "$@"; }
case "${1:?r1|r2|r3}" in
  r1) t --filter WorkCommandTests --filter CommandsTests --filter WorkLoopTests \
        && test "$(grep -rn 'preset must be' Sources | wc -l | tr -d ' ')" -le 1 ;;
  r2) t --filter LifecyclePassTests --filter LifecycleRulesTests --filter LifecycleInjectionTests --filter ConsolidationTests \
        && test "$(grep -rn 'withFullDate' Sources/CollieDaemonKit/Memory | wc -l | tr -d ' ')" -le 1 ;;
  r3) t --filter WorkStoreTests --filter WorkLoopTests \
        && ! grep -nE '^        let iso = ISO8601DateFormatter\(\)' Sources/CollieDaemonKit/Work/WorkStore.swift ;;
  *) echo "tarefa desconhecida: $1" >&2; exit 2 ;;
esac
