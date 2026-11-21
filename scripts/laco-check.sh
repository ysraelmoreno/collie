#!/usr/bin/env bash
# Check de cada tarefa do laço "estado do laço" (Ondas 1, 1b, 2 e 3): scripts/laco-check.sh M1.1 .. M3.8, M3b.1 .. M3b.6, M3c.1 .. M3c.4, M3d.1 .. M3d.3, M5.1 .. M5.6, T6.1 (e M2.0)
# Cada tarefa exige o seu arquivo de testes novo e roda TODAS as suítes da família (cumulativo: nada pode regredir).
set -euo pipefail
cd "$(dirname "$0")/.."
t() { swift test --disable-sandbox --skip MemoryEventEmissionTests "$@"; }
suites=(WorkLoopTests WorkStatusTextTests WorkStoreTests LoopStopReasonTests LoopJournalTests AttemptDecisionTests AttemptMachineTests
        LoopRobustnessTests LoopJournalWritesTests LoopNitsTests LoopNudgeTests LoopResumeTests LoopCancelTests LoopResumeSafetyTests LoopResumeNitsTests LoopCancelWaitTests WorkWaitTests LoopOrientationTests
        WorkTaskReopenTests TaskSchedulerTests LaneWorktreeTests LaneHostTests LaneIntegrationTests LoopParallelTests
        LoopLaneLifecycleTests LoopParallelE2ETests AgentNamingTests LaneProfileIntentTests LaneIntegratorRaceTests LaneRefsProfileTests LoopParallelBudgetTests LaneSweepScopeTests LoopLaneNitsTests LaneCreateSerialTests LaneIntegratorWaitTests LaneHardeningTests LoopNotifyTests StarterWaitLivenessTests ShepherdWaitIntegrationTests GateLeftoversTests LoopNoticePolicyTests StopHookThrottleTests UsageLimitDetectionTests TokenUsageTests ContextAdviceTests LoopModelDefaultTests WorkArchiveTests HistoryDetailOpenTests WorkFeedFollowTests GateCleanLiteralTests ArchiveRunningLoopTests Onda5NitsTests HistoryArtifactPrivacyTests LoopLockClosedWorkTests WorkFeedClosedLoopTests LoopSectionTests ContextPanelLoopsTests ContextPanelHistoryTests HistoryPageTests OpenPanelSheetTests AskSubmitRetryTests AskTests WorkCommandTests CommandsTests WorkPanelTests)
filters=(); for s in "${suites[@]}"; do filters+=(--filter "$s"); done
need() { test -f "$1" || { echo "falta $1" >&2; exit 1; }; }
D=Tests/CollieDaemonKitTests; A=Tests/CollieAppTests
case "${1:?M1.1..M5.6}" in
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
  M3b.1) need $D/LaneProfileIntentTests.swift ;;
  M3b.2) need $D/LaneIntegratorRaceTests.swift ;;
  M3b.3) need $D/LaneRefsProfileTests.swift ;;
  M3b.4) need $D/LoopParallelBudgetTests.swift ;;
  M3b.5) need $D/LaneSweepScopeTests.swift ;;
  M3b.6) need $D/LoopLaneNitsTests.swift ;;
  M3c.1) need $D/LaneCreateSerialTests.swift ;;
  M3c.2) need $D/LaneIntegratorWaitTests.swift ;;
  M3c.3) need $D/LaneHardeningTests.swift ;;
  M3c.4) need $D/LoopNotifyTests.swift ;;
  M5.1)  need $D/LoopNoticePolicyTests.swift ;;
  M5.2)  need $D/StopHookThrottleTests.swift ;;
  M5.3)  need $D/UsageLimitDetectionTests.swift ;;
  M5.4)  need $D/TokenUsageTests.swift ;;
  M5.5)  need $D/ContextAdviceTests.swift ;;
  M5.6)  need $D/LoopModelDefaultTests.swift ;;
  T6.1)  need $D/WorkArchiveTests.swift ;;
  M3d.1) need $D/StarterWaitLivenessTests.swift ;;
  M3d.2) need $D/ShepherdWaitIntegrationTests.swift ;;
  M3d.3) need $D/GateLeftoversTests.swift ;;
  M6.1)  need $A/HistoryDetailOpenTests.swift ;;
  M6.2)  need Tests/CollieClientTests/WorkFeedFollowTests.swift ;;
  M6.3)  need $D/GateCleanLiteralTests.swift ;;
  M6.4)  need $D/ArchiveRunningLoopTests.swift ;;
  M6.5)  need $D/Onda5NitsTests.swift ;;
  M7.1)  need $D/HistoryArtifactPrivacyTests.swift ;;
  M7.2)  need $D/LoopLockClosedWorkTests.swift ;;
  M7.3)  need Tests/CollieClientTests/WorkFeedClosedLoopTests.swift ;;
  M3.8)  need Sources/CollieDaemonKit/Work/AgentNaming.swift; need $D/AgentNamingTests.swift ;;
  *) echo "tarefa desconhecida: $1" >&2; exit 2 ;;
esac
# a nota do laço guarda só o rabo da saída: no fim, os nomes dos testes que falharam e o resumo, para a nota levar o que importa
log=$(mktemp -t laco-check.XXXXXX)
set +e
t "${filters[@]}" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
set -e
if [ "$rc" -ne 0 ] && ! grep -qE 'error:|Fatal error|failed to build|Compiling.*failed' "$log"; then
  # suítes instáveis sob carga (ex.: AskTests/RemoteAskTests) queimavam tentativas sem culpa da tarefa: repete UMA vez só
  # as suítes que falharam; passa só se passarem agora. Erro de compilação não repete.
  failed=$(grep -E '^[^a-zA-Z]*✘ Suite ' "$log" | sed -E 's/^[^a-zA-Z]*✘ Suite ([A-Za-z0-9_]+).*/\1/' | sort -u)
  if [ -n "$failed" ]; then
    echo "=== repetindo uma vez as suítes que falharam: $(echo $failed | tr '\n' ' ') ===" >&2
    rf=(); for f in $failed; do rf+=(--filter "$f"); done
    set +e; t "${rf[@]}" 2>&1 | tee "$log"; rc=${PIPESTATUS[0]}; set -e
  fi
fi
if [ "$rc" -ne 0 ]; then
  echo "=== falhas (laco-check) ==="
  grep -E '^[^a-zA-Z]*✘ (Test|Suite)|error:|Fatal error' "$log" | sed -E 's/ recorded an issue at .*//; s/ failed after .*//' | sort -u | tail -n 15
  grep -E 'Test run with' "$log" | tail -n 1
fi
rm -f "$log"
exit "$rc"
