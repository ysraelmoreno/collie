#!/usr/bin/env bash
# Checks of the F2 ninth fix loop (docs/superpowers/specs/dl22/*.md): scripts/check-f2fix9-loop.sh v1|v2|v3
set -euo pipefail
cd "$(dirname "$0")/.."
t() { swift test --disable-sandbox --skip MemoryEventEmissionTests "$@"; }
W=Sources/CollieDaemonKit
R="--filter WorkLoopReviewTests --filter ReviewVerdictTests --filter AttemptMachineTests --filter WorkLoopTests"
case "${1:?v1|v2|v3|v4|v3b}" in
  v1) t $R && grep -rq "lookForCommit" $W/Work && grep -rqE "ocupado" $W/Work ;;
  v2) t $R --filter WorkCommandTests --filter LaneHostTests && grep -rq "startedOpen" $W ;;
  v3) t $R --filter WorkCommandTests && grep -rq "hasTrustDialogAccepted" $W ;;
  v4) t $R --filter WorkCommandTests && grep -rq "loopReviewers.contains(denial" $W ;;
  v3b) t $R && grep -rq "O_EXCL" $W/Work ;;
  *) echo "tarefa desconhecida: $1" >&2; exit 2 ;;
esac
