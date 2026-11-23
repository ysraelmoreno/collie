#!/usr/bin/env bash
# Checks of the F2 fourth fix loop (docs/superpowers/specs/dl17/*.md): scripts/check-f2fix4-loop.sh w1|w2|w3
set -euo pipefail
cd "$(dirname "$0")/.."
t() { swift test --disable-sandbox --skip MemoryEventEmissionTests "$@"; }
W=Sources/CollieDaemonKit
R="--filter WorkLoopReviewTests --filter ReviewVerdictTests --filter AttemptMachineTests --filter WorkLoopTests"
case "${1:?w1|w2|w3}" in
  w1) t $R --filter AgentLaunchTests && grep -rq reviewerNoMcp $W ;;
  w2) t $R && grep -rq reviewSnapshot $W/Work ;;
  w3) t $R && grep -rq reviewConfigOthers $W/Work ;;
  *) echo "tarefa desconhecida: $1" >&2; exit 2 ;;
esac
