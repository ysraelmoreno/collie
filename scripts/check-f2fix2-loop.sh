#!/usr/bin/env bash
# Checks of the F2 second fix loop (docs/superpowers/specs/dl15/*.md): scripts/check-f2fix2-loop.sh y1|y2a|y2b|y2c
set -euo pipefail
cd "$(dirname "$0")/.."
t() { swift test --disable-sandbox --skip MemoryEventEmissionTests "$@"; }
W=Sources/CollieDaemonKit
R="--filter WorkLoopReviewTests --filter ReviewVerdictTests --filter AttemptMachineTests --filter WorkLoopTests"
case "${1:?y1|y2a|y2b|y2c}" in
  y1) t $R && grep -rq reviewRoot $W ;;
  y2) t $R --filter WorkStoreTests && grep -rq reviewMaxLinePaths $W/Work ;;
  y2a) t $R && grep -rq reviewerTouched $W/Work ;;
  y2b) t $R && grep -rq reviewMaxLinePaths $W/Work ;;
  y2c) t --filter WorkLoopReviewTests && grep -q "timeLimit" Tests/CollieDaemonKitTests/WorkLoopReviewTests.swift ;;
  *) echo "tarefa desconhecida: $1" >&2; exit 2 ;;
esac
