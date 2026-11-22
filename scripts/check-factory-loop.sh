#!/usr/bin/env bash
# Checks of the factory loop F2 (docs/superpowers/specs/dl13/*.md): scripts/check-factory-loop.sh r1|r5|r2|r3|r4
set -euo pipefail
cd "$(dirname "$0")/.."
t() { swift test --disable-sandbox --skip MemoryEventEmissionTests "$@"; }
W=Sources/CollieDaemonKit/Work
case "${1:?r1|r5|r2|r3|r4}" in
  r1) t --filter WorkCommandTests --filter WorkStoreTests && grep -rq reviewerModel $W ;;
  r5) t --filter PersonaTests && grep -q PersonaRouter $W/Persona.swift && test -s docs/fabrica/personas/correcao.md && test -s docs/fabrica/personas/motor-concorrencia.md && test -s docs/fabrica/personas/seguranca.md && test -s docs/fabrica/personas/testes.md && test -s docs/fabrica/personas/simplicidade.md ;;
  r2) t --filter ReviewVerdictTests && test -f $W/ReviewVerdict.swift ;;
  r3) t --filter AttemptMachineTests --filter AttemptDecisionTests && grep -q reviewing $W/AttemptMachine.swift ;;
  r4) t --filter WorkLoopReviewTests --filter WorkLoopTests --filter AttemptMachineTests && grep -rq WorkLoopReview Tests ;;
  *) echo "tarefa desconhecida: $1" >&2; exit 2 ;;
esac
