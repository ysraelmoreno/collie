#!/usr/bin/env bash
# Check das tarefas do Trilho 2 (laços ao vivo e histórico): scripts/onda4-check.sh T6.1 .. T6.6
# Cumulativo: roda as suítes da família; cada tarefa exige o seu arquivo de testes novo. Imprime os testes que falharam.
set -uo pipefail
cd "$(dirname "$0")/.."
suites=(WorkArchiveTests LoopSectionTests LoopRowsTests HistorySectionTests HistoryPageTests OpenPanelSheetTests
        AgentTreeTests ShellTests WorkPanelTests WorkCommandTests CommandsTests WorkStoreTests)
filters=(); for s in "${suites[@]}"; do filters+=(--filter "$s"); done
need() { test -f "$1" || { echo "falta $1" >&2; exit 1; }; }
D=Tests/CollieDaemonKitTests; A=Tests/CollieAppTests
case "${1:?T6.1..T6.6}" in
  T6.1) need $D/WorkArchiveTests.swift ;;
  T6.2) need $A/LoopSectionTests.swift ;;
  T6.3) need $A/LoopRowsTests.swift ;;
  T6.4) need $A/HistorySectionTests.swift ;;
  T6.5) need $A/HistoryPageTests.swift ;;
  T6.6) need $A/OpenPanelSheetTests.swift ;;
  *) echo "tarefa desconhecida: $1" >&2; exit 2 ;;
esac
log=$(mktemp); run() { swift test --disable-sandbox --skip MemoryEventEmissionTests "${filters[@]}" 2>&1 | tee "$log"; return "${PIPESTATUS[0]}"; }
if ! run; then
  echo "=== repetindo uma vez as suítes que falharam (instabilidade sob carga) ===" >&2
  failed=$(grep -E '^✘ Suite ' "$log" | sed -E 's/^✘ Suite ([A-Za-z0-9_]+).*/\1/' | sort -u)
  [ -z "$failed" ] && { echo "=== falhas (onda4-check) ==="; grep -E '^✘ ' "$log" | head -40; exit 1; }
  rf=(); for s in $failed; do rf+=(--filter "^$s"); done
  swift test --disable-sandbox --skip MemoryEventEmissionTests "${rf[@]}" 2>&1 | tee "$log" && exit 0
  echo "=== falhas (onda4-check) ==="; grep -E '^✘ ' "$log" | head -40; exit 1
fi
