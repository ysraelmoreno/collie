#!/usr/bin/env bash
# Check de cada tarefa do laço "estado do laço": scripts/laco-check.sh <tarefa> (M1.1 .. M11.4) ou scripts/laco-check.sh --full [<tarefa>]
# Cada tarefa exige o seu arquivo (need). Um caso com `area=(Suíte …)` roda só a área + a fumaça fixa; um caso sem `area`
# roda o cumulativo inteiro (nenhuma tarefa antiga perde cobertura). A área é declarada no case, nunca inferida do diff.
# --full (ou LACO_FULL=1) roda a lista inteira de uma vez: o portão do Pastor no fim da onda e antes do merge.
# Cada nome é conferido contra os testes (swift test list --skip-build, ou a declaração em Tests/): nome sem suíte é erro.
set -euo pipefail
cd "$(dirname "$0")/.."
t() { swift test --disable-sandbox --skip MemoryEventEmissionTests "$@"; }
suites=(WorkLoopTests WorkStatusTextTests WorkStoreTests LoopStopReasonTests LoopJournalTests AttemptDecisionTests AttemptMachineTests
        LoopRobustnessTests LoopJournalWritesTests LoopNitsTests LoopNudgeTests LoopResumeTests LoopCancelTests LoopResumeSafetyTests LoopResumeNitsTests LoopCancelWaitTests WorkWaitTests LoopOrientationTests
        WorkTaskReopenTests TaskSchedulerTests LaneWorktreeTests LaneHostTests LaneIntegrationTests LoopParallelTests
        LoopLaneLifecycleTests LoopParallelE2ETests AgentNamingTests LaneProfileIntentTests LaneIntegratorRaceTests LaneRefsProfileTests LoopParallelBudgetTests LaneSweepScopeTests LoopLaneNitsTests LaneCreateSerialTests LaneIntegratorWaitTests LaneHardeningTests LoopNotifyTests StarterWaitLivenessTests ShepherdWaitIntegrationTests GateLeftoversTests LoopNoticePolicyTests StopHookThrottleTests UsageLimitDetectionTests TokenUsageTests ContextAdviceTests LoopModelDefaultTests WorkArchiveTests HistoryDetailOpenTests WorkFeedFollowTests GateCleanLiteralTests ArchiveRunningLoopTests Onda5NitsTests HistoryArtifactPrivacyTests LoopLockClosedWorkTests WorkFeedClosedLoopTests HistoryRealWorksTests LoopSectionAttemptTests LoopCardTests LoopsModalTests HistoryReachTests DiscardRawNamesTests PastorContextLifecycleTests TurnSafetyTests ArchiveUsageTests InjectionDedupTests TerminalFullscreenClickTests ChecklistTests ChecklistRankingTests LoopSectionTests LoopRowsTests HistorySectionTests HistoryPageTests OpenPanelSheetTests AskSubmitRetryTests AskTests WorkCommandTests CommandsTests WorkPanelTests
        AskClockTests RemoteAskTests StableBuildDirTests CollieOrientationTests)
# fumaça fixa: roda em todo check de área
smoke=(WorkLoopTests AttemptMachineTests WorkStoreTests LoopJournalTests CommandsTests)
full=${LACO_FULL:-0}
if [ "${1:-}" = "--full" ]; then full=1; shift; fi
task=${1:-}
[ -n "$task" ] || [ "$full" = 1 ] || { echo "uso: scripts/laco-check.sh <tarefa M1.1..M11.4> | --full [<tarefa>]" >&2; exit 2; }
need() { test -f "$1" || { echo "falta $1" >&2; exit 1; }; }
D=Tests/CollieDaemonKitTests; A=Tests/CollieAppTests
case "$task" in
  "")    ;; # --full sem tarefa: só o portão
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
  M8.1)  need $A/LoopSectionAttemptTests.swift; need $D/HistoryRealWorksTests.swift ;;
  M8.2)  need $A/LoopCardTests.swift ;;
  M8.3)  need $A/LoopsModalTests.swift ;;
  M9.1)  need $A/HistoryReachTests.swift ;;
  M9.2)  need $D/DiscardRawNamesTests.swift ;;
  M10.1) need $D/PastorContextLifecycleTests.swift ;;
  M10.2) need $D/TurnSafetyTests.swift ;;
  M10.3) need $D/ArchiveUsageTests.swift ;;
  M10.4) need $D/InjectionDedupTests.swift ;;
  M10.5) need $A/TerminalFullscreenClickTests.swift ;;
  M3.8)  need Sources/CollieDaemonKit/Work/AgentNaming.swift; need $D/AgentNamingTests.swift ;;
  M11.1) need $D/AskClockTests.swift; area=(AskClockTests AskTests RemoteAskTests AskSubmitRetryTests) ;;
  M11.2) need scripts/ci/test-run-tests.sh; area=() ;; # só CI: a área Swift é vazia, roda a fumaça
  M11.3) need $D/StableBuildDirTests.swift; area=(StableBuildDirTests CollieOrientationTests LoopOrientationTests) ;;
  M11.4) need scripts/test-laco-check.sh; area=() ;; # só o script do check: roda a fumaça
  *) echo "tarefa desconhecida: $1" >&2; exit 2 ;;
esac
# o que roda: --full ou caso sem área = a lista inteira; caso com área = área + fumaça (sem repetir nome)
if [ "$full" = 1 ] || ! declare -p area >/dev/null 2>&1; then
  run=("${suites[@]}"); what="cumulativo (${#suites[@]} suítes)"
else
  run=()
  for s in ${area[@]+"${area[@]}"} "${smoke[@]}"; do
    case " ${run[*]-} " in *" $s "*) ;; *) run+=("$s") ;; esac
  done
  what="área + fumaça (${#run[@]} suítes)"
fi
# filtros validados: cada nome tem de casar uma suíte (nome colado ou inexistente rodaria 0 testes e passaria calado)
listed=$(swift test list --skip-build 2>/dev/null || true)
bad=()
for s in "${run[@]}"; do
  [[ "$s" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { bad+=("$s"); continue; }
  grep -qE "\.$s/" <<< "$listed" && continue
  grep -rqE --include='*.swift' "(struct|class|actor|enum)[[:space:]]+$s([^A-Za-z0-9_]|\$)" Tests/ 2>/dev/null && continue
  bad+=("$s")
done
if [ "${#bad[@]}" -gt 0 ]; then
  for s in "${bad[@]}"; do echo "filtro sem suíte: $s" >&2; done
  exit 3
fi
# ancorado: \.AskTests/ não casa RemoteAskTests
anchored() { filters=(); for s in "$@"; do filters+=(--filter "\\.$s/"); done; }
anchored "${run[@]}"
echo "=== laco-check ${task:-portão} ($what) ===" >&2
# a nota do laço guarda só o rabo da saída: no fim, os nomes dos testes que falharam e o resumo, para a nota levar o que importa
log=$(mktemp -t laco-check.XXXXXX)
set +e
t "${filters[@]}" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
set -e
if [ "$rc" -ne 0 ] && ! grep -qE 'error:|Fatal error|failed to build|Compiling.*failed' "$log"; then
  # suítes instáveis sob carga queimavam tentativas sem culpa da tarefa: repete UMA vez só as suítes que falharam;
  # passa só se passarem agora. Erro de compilação não repete. Imprime o que repetiu e quanto custou (instável se conserta).
  failed=$(grep -E '^[^a-zA-Z]*✘ Suite ' "$log" | sed -E 's/^[^a-zA-Z]*✘ Suite ([A-Za-z0-9_]+).*/\1/' | sort -u | tr '\n' ' ')
  failed=${failed% }
  if [ -n "$failed" ]; then
    echo "=== repetindo uma vez as suítes que falharam: $failed ===" >&2
    anchored $failed
    t0=$SECONDS
    set +e; t "${filters[@]}" 2>&1 | tee "$log"; rc=${PIPESTATUS[0]}; set -e
    echo "=== repetição: $failed: $((SECONDS - t0))s, $([ "$rc" -eq 0 ] && echo passou || echo falhou de novo) ===" >&2
  fi
fi
if [ "$rc" -ne 0 ]; then
  echo "=== falhas (laco-check) ==="
  grep -E '^[^a-zA-Z]*✘ (Test|Suite)|error:|Fatal error' "$log" | sed -E 's/ recorded an issue at .*//; s/ failed after .*//' | sort -u | tail -n 15
  grep -E 'Test run with' "$log" | tail -n 1
fi
rm -f "$log"
exit "$rc"
