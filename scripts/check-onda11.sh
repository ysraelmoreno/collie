#!/usr/bin/env bash
# Checks of the Onda 11 tasks (docs/superpowers/roadmap/2026-11-20-estado-do-laco/onda11.md): scripts/check-onda11.sh m11-1 .. q11-4
set -euo pipefail
cd "$(dirname "$0")/.."
t() { swift test --disable-sandbox --skip MemoryEventEmissionTests "$@"; }
gate() { scripts/ci/lint.sh && scripts/ci/check-architecture.sh; }
Q=Examples/apps/quadro
case "${1:?m11-1..q11-4}" in
  m11-1) t --filter AskClockTests --filter AskTests --filter RemoteAskTests --filter AskSubmitRetryTests ;;
  m11-2) bash -n scripts/ci/run-tests.sh && scripts/ci/test-run-tests.sh && gate ;;
  m11-3) t --filter StableBuildDirTests --filter OrientationTests && scripts/dev/test-prune-builds.sh ;;
  m11-4) bash -n scripts/laco-check.sh && scripts/test-laco-check.sh && gate ;;
  q11-1) (cd $Q && python3 -m unittest tests.test_store -v) ;;
  q11-2) (cd $Q && python3 -m unittest tests.test_store tests.test_server -v) ;;
  q11-3) (cd $Q && python3 -m unittest tests.test_ui -v) ;;
  q11-4) (cd $Q && python3 -m unittest discover -s tests -v && bash -n run.sh) && gate ;;
  *) echo "tarefa desconhecida: $1" >&2; exit 2 ;;
esac
