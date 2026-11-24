#!/usr/bin/env bash
# Checks of the auto-land tasks (docs/superpowers/specs/autoland/*.md): scripts/check-autoland-loop.sh a1|a2
set -euo pipefail
cd "$(dirname "$0")/.."
t() { swift test --disable-sandbox --skip MemoryEventEmissionTests "$@"; }
case "${1:?a1|a2}" in
  a1) t --filter FactoryRunProfileTests --filter ProjectWorkConfigTests --filter FactoryProfileTests --filter WorkCommandTests --filter WorkLoopTests ;;
  a2) t --filter PaddockFactoryTests --filter PaddockModelTests --filter FactoryDoctorTests --filter CommandsTests ;;
  *) echo "tarefa desconhecida: $1" >&2; exit 2 ;;
esac
