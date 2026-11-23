#!/usr/bin/env bash
# Checks of the F2 sixth fix loop (docs/superpowers/specs/dl19/*.md): scripts/check-f2fix6-loop.sh u1|u2
set -euo pipefail
cd "$(dirname "$0")/.."
t() { swift test --disable-sandbox --skip MemoryEventEmissionTests "$@"; }
W=Sources/CollieDaemonKit
R="--filter WorkLoopReviewTests --filter ReviewVerdictTests --filter AttemptMachineTests --filter WorkLoopTests"
case "${1:?u1|u2}" in
  u1) t $R && grep -rq reviewLoopConfigBase $W/Work ;;
  u2) t $R --filter GitRunnerTests && grep -rq reviewNoReplace $W ;;
  *) echo "tarefa desconhecida: $1" >&2; exit 2 ;;
esac
