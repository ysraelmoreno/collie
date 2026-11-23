#!/usr/bin/env bash
# Checks of the F2 third fix loop (docs/superpowers/specs/dl16/*.md): scripts/check-f2fix3-loop.sh z1|z2|z3a|z3b
set -euo pipefail
cd "$(dirname "$0")/.."
t() { swift test --disable-sandbox --skip MemoryEventEmissionTests "$@"; }
W=Sources/CollieDaemonKit
R="--filter WorkLoopReviewTests --filter ReviewVerdictTests --filter AttemptMachineTests --filter WorkLoopTests"
case "${1:?z1|z2|z3a|z3b}" in
  z1) t $R --filter MemoryCommandTests && grep -rq reviewerHooksBare $W ;;
  z2) t $R --filter WorkCommandTests && grep -rq reviewNeedsStrict $W ;;
  z3a) t $R && grep -rq reviewBudgetOut $W/Work ;;
  z3b) t $R && grep -rq reviewHashAgentConfig $W/Work ;;
  *) echo "tarefa desconhecida: $1" >&2; exit 2 ;;
esac
