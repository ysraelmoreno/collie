#!/usr/bin/env bash
# Checks of the Onda 13 tasks (docs/superpowers/roadmap/2026-11-20-estado-do-laco/onda13.md): scripts/check-onda13.sh m13-1 .. m13-4
set -euo pipefail
cd "$(dirname "$0")/.."
t() { swift test --disable-sandbox --skip MemoryEventEmissionTests "$@"; }
case "${1:?m13-1..m13-4}" in
  m13-1) t --filter ProjectWorkConfigTests ;;
  m13-2) t --filter ProjectWorkConfigTests --filter WorkAreaTests --filter WorkCommandTests ;;
  m13-3) t --filter ProjectWorkConfigTests --filter WorkAreaTests --filter WorkConfigTamperTests --filter WorkLoopTests --filter AttemptMachineTests ;;
  m13-4) t --filter WebPluginPanelTests --filter AppPanelBlankTests && scripts/ci/lint.sh && scripts/ci/check-architecture.sh ;;
  *) echo "tarefa desconhecida: $1" >&2; exit 2 ;;
esac
