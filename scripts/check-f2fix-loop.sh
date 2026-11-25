#!/usr/bin/env bash
# Checks of the F2 fix loop (docs/superpowers/specs/dl14/*.md): scripts/check-f2fix-loop.sh x1..x5
set -euo pipefail
cd "$(dirname "$0")/.."
t() { swift test --disable-sandbox --skip MemoryEventEmissionTests "$@"; }
W=Sources/CollieDaemonKit
R="--filter WorkLoopReviewTests --filter ReviewVerdictTests --filter AttemptMachineTests --filter WorkLoopTests"
case "${1:?x1..x5}" in
  x1) t $R && grep -rq reviewScratch $W ;;
  x2) t $R && grep -q nonce $W/Work/ReviewVerdict.swift ;;
  x3) t $R --filter WorkStoreTests && grep -rq reviewMinTurn $W/Work ;;
  x4) t $R --filter PersonaTests --filter WorkCommandTests && grep -rq "sem spec no commit base" $W ;;
  x5) t $R --filter PersonaTests && ! grep -q "linha do DIFF recebido" docs/fabrica/personas/*.md ;;
  *) echo "tarefa desconhecida: $1" >&2; exit 2 ;;
esac
