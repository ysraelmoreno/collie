#!/usr/bin/env bash
# Checks of the Onda 12 tasks (docs/superpowers/roadmap/2026-11-20-estado-do-laco/onda12.md): scripts/check-onda12.sh q12-1 .. q12-3
set -euo pipefail
cd "$(dirname "$0")/.."
Q=Examples/apps/quadro
gate() { scripts/ci/lint.sh && scripts/ci/check-architecture.sh; }
export PYTHONDONTWRITEBYTECODE=1
case "${1:?q12-1..q12-3}" in
  q12-1) (cd $Q && python3 -m unittest tests.test_store tests.test_server -v) ;;
  q12-2) (cd $Q && python3 -m unittest discover -s tests -v && bash -n run.sh) && gate ;;
  q12-3) (cd $Q && python3 -m unittest tests.test_ui -v) ;;
  *) echo "tarefa desconhecida: $1" >&2; exit 2 ;;
esac
