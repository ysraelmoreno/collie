#!/usr/bin/env bash
# Checks of the F2 fifth fix loop (docs/superpowers/specs/dl18/*.md): scripts/check-f2fix5-loop.sh v1|v2|v3
set -euo pipefail
cd "$(dirname "$0")/.."
t() { swift test --disable-sandbox --skip MemoryEventEmissionTests "$@"; }
W=Sources/CollieDaemonKit
R="--filter WorkLoopReviewTests --filter ReviewVerdictTests --filter AttemptMachineTests --filter WorkLoopTests"
case "${1:?v1|v2|v3}" in
  v1) t $R && grep -rq reviewSnapshotOutside $W/Work ;;
  v2) t $R && grep -rq reviewGlobalConfigHash $W/Work ;;
  v3) t $R --filter MemoryCommandTests && grep -rq reviewMemoryDenied $W ;;
  *) echo "tarefa desconhecida: $1" >&2; exit 2 ;;
esac
