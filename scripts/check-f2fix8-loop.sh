#!/usr/bin/env bash
# Checks of the F2 eighth fix loop (docs/superpowers/specs/dl21/*.md): scripts/check-f2fix8-loop.sh t1|t2
set -euo pipefail
cd "$(dirname "$0")/.."
t() { swift test --disable-sandbox --skip MemoryEventEmissionTests "$@"; }
W=Sources/CollieDaemonKit
R="--filter WorkLoopReviewTests --filter ReviewVerdictTests --filter AttemptMachineTests --filter WorkLoopTests"
case "${1:?t1|t2}" in
  t1) t $R && grep -rq reviewOneCopy $W/Work ;;
  t2) t $R --filter GitRunnerTests && grep -rq reviewVetoKept $W/Work ;;
  *) echo "tarefa desconhecida: $1" >&2; exit 2 ;;
esac
