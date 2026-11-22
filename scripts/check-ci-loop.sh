#!/usr/bin/env bash
# Checks of the CI loop (docs/superpowers/specs/dl8/*.md): scripts/check-ci-loop.sh c0..c7
set -euo pipefail
cd "$(dirname "$0")/.."
t() { swift test --disable-sandbox --skip MemoryEventEmissionTests "$@"; }
case "${1:?c0..c7}" in
  c0) scripts/ci/test-run-tests.sh && grep -q "BrowserInputTests" scripts/ci/ci-skip.txt ;;
  c1) t --filter RouterTests && ! grep -n 'await d.process(.*)!' Tests/CollieDaemonKitTests/RouterTests.swift ;;
  c2) t --filter DeviceHelperTests ;;
  c3) t --filter AskTests ;;
  c4) t --filter DaemonClientTests ;;
  c5) t --filter PTYProcessTests ;;
  c6) t --filter TerminalFullscreenClickTests ;;
  c7) t --filter MCPTests ;;
  *) echo "tarefa desconhecida: $1" >&2; exit 2 ;;
esac
