#!/usr/bin/env bash
# Checks of the device loop tasks (docs/superpowers/specs/2026-11-21-device-agent-loop-design.md): scripts/check-device-loop.sh d1 .. d4
set -euo pipefail
cd "$(dirname "$0")/.."
t() { swift test --disable-sandbox --skip MemoryEventEmissionTests "$@"; }
case "${1:?d1..d4}" in
  d1) t --filter CollieDeviceTests --filter DeviceCommandTests --filter SimCommandTests --filter CommandsTests \
      && grep -q "compact" Sources/CollieDevice/UITree.swift ;;
  d2) t --filter DeviceCommandTests --filter SimCommandTests --filter CommandsTests \
      && grep -q "settle" Sources/CollieProtocol/Plugins.swift ;;
  d3) t --filter DeviceCommandTests --filter SimCommandTests --filter CommandsTests \
      && grep -q '"text"' Sources/CollieProtocol/Plugins.swift ;;
  d4) t --filter CollieOrientationTests && grep -q "device ui" Sources/CollieDaemonKit/CollieOrientation.swift ;;
  *) echo "tarefa desconhecida: $1" >&2; exit 2 ;;
esac
