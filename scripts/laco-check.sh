#!/usr/bin/env bash
# Check de cada tarefa do laço "estado do laço" (Onda 1): scripts/laco-check.sh M1.1..M1.4
set -euo pipefail
cd "$(dirname "$0")/.."
t() { swift test --disable-sandbox --skip MemoryEventEmissionTests "$@"; }
base=(--filter WorkLoopTests --filter WorkStatusTextTests --filter WorkStoreTests)
case "${1:?M1.1..M1.4}" in
  M1.1) grep -q 'stopReason' Sources/CollieCore/Work.swift && test -f Tests/CollieDaemonKitTests/LoopStopReasonTests.swift && t "${base[@]}" --filter LoopStopReasonTests ;;
  M1.2) grep -q 'struct LoopEvent' Sources/CollieCore/Work.swift && test -f Tests/CollieDaemonKitTests/LoopJournalTests.swift && t "${base[@]}" --filter LoopStopReasonTests --filter LoopJournalTests ;;
  M1.3) test -f Sources/CollieDaemonKit/Work/AttemptDecision.swift && test -f Tests/CollieDaemonKitTests/AttemptDecisionTests.swift && t "${base[@]}" --filter LoopStopReasonTests --filter LoopJournalTests --filter AttemptDecisionTests ;;
  M1.4) test -f Sources/CollieDaemonKit/Work/AttemptMachine.swift && test -f Tests/CollieDaemonKitTests/AttemptMachineTests.swift && t "${base[@]}" --filter LoopStopReasonTests --filter LoopJournalTests --filter AttemptDecisionTests --filter AttemptMachineTests ;;
  *) echo "tarefa desconhecida: $1" >&2; exit 2 ;;
esac
