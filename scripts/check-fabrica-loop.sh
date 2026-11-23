#!/usr/bin/env bash
# Checks of the Fábrica para usuários tasks (docs/superpowers/specs/fabrica/*.md): scripts/check-fabrica-loop.sh u1
set -euo pipefail
cd "$(dirname "$0")/.."
t() { swift test --disable-sandbox --skip MemoryEventEmissionTests "$@"; }
case "${1:?u1}" in
  u1) t --filter FactoryProfileTests --filter ProjectWorkConfigTests --filter WorkAreaTests --filter WorkConfigTamperTests \
        && test -f Sources/CollieCore/FactoryProfile.swift && grep -q "invalidFactory" Sources/CollieCore/ProjectWorkConfig.swift ;;
  *) echo "tarefa desconhecida: $1" >&2; exit 2 ;;
esac
