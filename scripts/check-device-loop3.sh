#!/usr/bin/env bash
# Checks of device loop 3 (docs/superpowers/specs/dl3/*.md): scripts/check-device-loop3.sh w1|f1
set -euo pipefail
cd "$(dirname "$0")/.."
t() { swift test --disable-sandbox --skip MemoryEventEmissionTests "$@"; }
D="--filter DeviceCommandTests --filter SimCommandTests --filter CommandsTests"
case "${1:?w1 f1}" in
  w1) t $D && grep -rq waitTimeoutParses Tests ;;
  f1) t $D --filter CollieDeviceTests && grep -rq humanizeId Sources/CollieDevice && grep -rq humanizeIdCases Tests ;;
  *) echo "tarefa desconhecida: $1" >&2; exit 2 ;;
esac
