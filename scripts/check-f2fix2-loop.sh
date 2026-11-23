#!/usr/bin/env bash
# Checks of the F2 second fix loop (docs/superpowers/specs/dl15/*.md): scripts/check-f2fix2-loop.sh y1|y2
set -euo pipefail
cd "$(dirname "$0")/.."
t() { swift test --disable-sandbox --skip MemoryEventEmissionTests "$@"; }
W=Sources/CollieDaemonKit
R="--filter WorkLoopReviewTests --filter ReviewVerdictTests --filter AttemptMachineTests --filter WorkLoopTests"
case "${1:?y1|y2}" in
  y1) t $R && grep -rq reviewRoot $W ;;
  y2) t $R --filter WorkStoreTests && grep -rq reviewMaxLinePaths $W/Work ;;
  *) echo "tarefa desconhecida: $1" >&2; exit 2 ;;
esac
