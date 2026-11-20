#!/usr/bin/env bash
# Check de cada tarefa do laço "estado do laço" (Ondas 1, 1b, 2 e 3): scripts/laco-check.sh M1.1 .. M3.7 (e M2.0)
# Cada tarefa exige o seu arquivo de testes novo e roda TODAS as suítes da família (cumulativo: nada pode regredir).
set -euo pipefail
cd "$(dirname "$0")/.."
t() { swift test --disable-sandbox --skip MemoryEventEmissionTests "$@"; }
suites=(WorkLoopTests WorkStatusTextTests WorkStoreTests LoopStopReasonTests LoopJournalTests AttemptDecisionTests AttemptMachineTests
        LoopRobustnessTests LoopJournalWritesTests LoopNitsTests LoopNudgeTests LoopResumeTests LoopCancelTests LoopResumeSafetyTests LoopResumeNitsTests LoopCancelWaitTests WorkWaitTests LoopOrientationTests
        WorkTaskReopenTests TaskSchedulerTests LaneWorktreeTests LaneHostTests LaneIntegrationTests LoopParallelTests
        LoopLaneLifecycleTests LoopParallelE2ETests AskSubmitRetryTests AskTests WorkCommandTests CommandsTests WorkPanelTests)
filters=(); for s in "${suites[@]}"; do filters+=(--filter "$s"); done
need() { test -f "$1" || { echo "falta $1" >&2; exit 1; }; }
D=Tests/CollieDaemonKitTests
case "${1:?M1.1..M3.7}" in
  M1.1)  grep -q stopReason Sources/CollieCore/Work.swift; need $D/LoopStopReasonTests.swift ;;
  M1.2)  grep -q 'struct LoopEvent' Sources/CollieCore/Work.swift; need $D/LoopJournalTests.swift ;;
  M1.3)  need Sources/CollieDaemonKit/Work/AttemptDecision.swift; need $D/AttemptDecisionTests.swift ;;
  M1.4)  need Sources/CollieDaemonKit/Work/AttemptMachine.swift; need $D/AttemptMachineTests.swift ;;
  M1b.1) need $D/LoopRobustnessTests.swift ;;
  M1b.2) need $D/LoopJournalWritesTests.swift ;;
  M1b.3) need $D/LoopNitsTests.swift ;;
  M2b.1) need $D/LoopResumeSafetyTests.swift ;;
  M2b.2) need $D/LoopCancelWaitTests.swift ;;
  M2c)   need $D/LoopResumeNitsTests.swift ;;
  M2.0)  need $D/AskSubmitRetryTests.swift ;;
  M2.1)  need $D/LoopNudgeTests.swift ;;
  M2.2)  need $D/LoopResumeTests.swift ;;
  M2.2a) need $D/LoopResumeTests.swift ;;
  M2.2b) need $D/LoopCancelTests.swift ;;
  M2.3)  need $D/WorkWaitTests.swift ;;
  M2.4)  need $D/LoopOrientationTests.swift ;;
  M2.5)  need $D/WorkTaskReopenTests.swift ;;
  M3.1)  need Sources/CollieDaemonKit/Work/TaskScheduler.swift; need $D/TaskSchedulerTests.swift ;;
  M3.2)  need Sources/CollieDaemonKit/Work/LaneWorktree.swift; need $D/LaneWorktreeTests.swift ;;
  M3.3)  need $D/LaneHostTests.swift ;;
  M3.4)  need Sources/CollieDaemonKit/Work/LaneIntegrator.swift; need $D/LaneIntegrationTests.swift ;;
  M3.5)  need $D/LoopParallelTests.swift ;;
  M3.6)  need $D/LoopLaneLifecycleTests.swift ;;
  M3.7)  need $D/LoopParallelE2ETests.swift ;;
  *) echo "tarefa desconhecida: $1" >&2; exit 2 ;;
esac
# a nota do laço guarda só o rabo da saída: no fim, os nomes dos testes que falharam e o resumo, para a nota levar o que importa
log=$(mktemp -t laco-check.XXXXXX)
set +e
t "${filters[@]}" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
set -e
if [ "$rc" -ne 0 ]; then
  echo "=== falhas (laco-check) ==="
  grep -E '^[^a-zA-Z]*✘ (Test|Suite)|error:|Fatal error' "$log" | sed -E 's/ recorded an issue at .*//; s/ failed after .*//' | sort -u | tail -n 15
  grep -E 'Test run with' "$log" | tail -n 1
fi
rm -f "$log"
exit "$rc"
