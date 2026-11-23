#!/usr/bin/env bash
# Checks of the F2 advisory loop (docs/superpowers/specs/dl20/*.md): scripts/check-f2fix7-loop.sh a1|a2
set -euo pipefail
cd "$(dirname "$0")/.."
t() { swift test --disable-sandbox --skip MemoryEventEmissionTests "$@"; }
W=Sources/CollieDaemonKit
R="--filter WorkLoopReviewTests --filter ReviewVerdictTests --filter AttemptMachineTests --filter WorkLoopTests"
case "${1:?a1|a2}" in
  a1) t $R && grep -rq reviewAdvisory $W/Work ;;
  a2) t $R --filter OrientationTests --filter CommandsTests && grep -q reviewAdvisoryDoc docs/referencia.md ;;
  *) echo "tarefa desconhecida: $1" >&2; exit 2 ;;
esac
