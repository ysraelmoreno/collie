#!/usr/bin/env bash
# Checks of the CI loop 2 (docs/superpowers/specs/dl12/*.md): scripts/check-ci-loop2.sh d0..d4
set -euo pipefail
cd "$(dirname "$0")/.."
t() { swift test --disable-sandbox --skip MemoryEventEmissionTests "$@"; }
case "${1:?d0..d4}" in
  d0) scripts/ci/test-run-tests.sh && grep -q "BrowserInputTests" scripts/ci/ci-skip.txt && ! grep -qE "BrowserInputTests/iframeTyping" scripts/ci/ci-skip.txt || scripts/ci/test-run-tests.sh && grep -qE "BrowserInputTests/?\)?" scripts/ci/ci-skip.txt ;;
  d1) scripts/ci/test-run-tests.sh && grep -q "TerminalFullscreenClickTests" scripts/ci/ci-skip.txt ;;
  d2) t --filter HerdApplyTests --filter WorkLoopCommandTests --filter ShepherdTests ;;
  d3) t --filter VizinhoPluginTests ;;
  d4) t --filter WorkMemoryTests ;;
  *) echo "tarefa desconhecida: $1" >&2; exit 2 ;;
esac
