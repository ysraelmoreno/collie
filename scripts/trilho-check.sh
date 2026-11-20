#!/usr/bin/env bash
# Check de cada tarefa do laço Trilho: scripts/trilho-check.sh T1..T5
set -euo pipefail
cd "$(dirname "$0")/.."
t() { swift test --disable-sandbox --skip MemoryEventEmissionTests "$@"; }
case "${1:?T1..T5}" in
  T1) test -f Sources/CollieApp/AgentTree.swift && test -f Tests/CollieAppTests/AgentTreeTests.swift && t --filter AgentTreeTests ;;
  T2) test -f Sources/CollieApp/PaddockRail.swift && test -f Tests/CollieAppTests/PaddockRailTests.swift && t --filter PaddockRailTests ;;
  T3) test -f Sources/CollieApp/ContextPanel.swift && ! grep -q 'struct WorkspaceSidebar' Sources/CollieApp/Shell.swift && t --filter ShellTests ;;
  T4) test -f Tests/CollieAppTests/MainViewTests.swift && t --filter MainViewTests --filter ShellTests ;;
  T5) grep -q appSettings Sources/CollieApp/CollieApp.swift && grep -q 'func openPreferences' Sources/CollieApp/CollieApp.swift && t --filter MainViewTests --filter PreferencePageTests ;;
  *) echo "tarefa desconhecida: $1" >&2; exit 2 ;;
esac
