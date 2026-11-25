#!/usr/bin/env bash
# Checks of the auto-land tasks (docs/superpowers/specs/autoland/*.md): scripts/check-autoland-loop.sh a1|a2|b1|p1|p2|c1|a3|a4|a5|a6|c2|f3|f5|f1|c3a|c3b|p3
set -euo pipefail
cd "$(dirname "$0")/.."
t() { swift test --disable-sandbox --skip MemoryEventEmissionTests "$@"; }
case "${1:?a1|a2|b1|p1|p2|c1|a3|a4|a5|a6|c2|f3|f5|f1|c3a|c3b|p3}" in
  a1) t --filter FactoryRunProfileTests --filter ProjectWorkConfigTests --filter FactoryProfileTests --filter WorkCommandTests --filter WorkLoopTests ;;
  a2) t --filter PaddockFactoryTests --filter PaddockModelTests --filter FactoryDoctorTests --filter CommandsTests ;;
  b1) t --filter FactoryRunProfileTests --filter PaddockFactoryTests --filter WorkCommandTests --filter CommandsTests --filter WorkLoopTests --filter FactoryDoctorTests ;;
  p1) t --filter WorkLoopReviewTests --filter ReviewVerdictTests --filter WorkLoopTests --filter AttemptMachineTests ;;
  p2) t --filter AttemptMachineTests --filter WorkLoopTests --filter LoopJournalTests --filter AskTests --filter WorkLoopReviewTests ;;
  c1) t --filter WorkLoopReviewTests --filter AttemptMachineTests --filter WorkLoopTests --filter PaddockFactoryTests --filter LoopJournalTests ;;
  a3) t --filter PaddockFactoryTests --filter ContextPanelFactoryTests --filter PaddockActionsTests --filter NewPaddockFormTests ;;
  a4) t --filter AutoLandTests --filter WorkLoopTests --filter AttemptMachineTests --filter PaddockFactoryTests ;;
  a5) t --filter AutoLandTests --filter FactoryProfileTests --filter WorkLoopTests ;;
  a6) t --filter AutoLandSummaryTests --filter AutoLandTests --filter WorkLoopTests ;;
  c2) t --filter AutoLandSummaryTests --filter AutoLandTests --filter FactoryDoctorTests --filter WorkLoopTests ; scripts/test-factory-detect.sh ;;
  f3) t --filter AcceptTests --filter AutoLandTests --filter AttemptMachineTests --filter WorkLoopTests --filter WorkStoreTests ;;
  f5) t --filter PrdStoreTests --filter PlanLintTests --filter PlanApplyTests --filter WorkCommandTests ;;
  f1) t --filter TrapCandidateTests --filter WorkLoopTests ;;
  c3a) t --filter AutoLandTests --filter AutoLandSummaryTests --filter FactoryDoctorTests --filter WorkLoopTests --filter PaddockFactoryTests ;;
  c3b) t --filter AutoLandTests --filter WorkLoopTests --filter WorkCommandTests --filter LotBoardTests ;;
  p3) t --filter AttemptMachineTests --filter WorkLoopTests --filter AskTests --filter WorkLoopReviewTests ;;
  *) echo "tarefa desconhecida: $1" >&2; exit 2 ;;
esac
