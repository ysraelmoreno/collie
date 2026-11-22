#!/usr/bin/env bash
# Checks of device loop 6 (docs/superpowers/specs/dl6/*.md): scripts/check-device-loop6.sh p1|p2|p3
set -euo pipefail
cd "$(dirname "$0")/.."
t() { swift test --disable-sandbox --skip MemoryEventEmissionTests "$@"; }
D="--filter DeviceCommandTests --filter SimCommandTests --filter CommandsTests --filter DeviceHelperTests --filter OCRTests --filter ScreenModelTests --filter CollieDeviceTests"
case "${1:?p1|p2|p3}" in
  p1) t --filter DeviceHelperTests --filter HelperProtocolTests && grep -rqE 'version *= *3' Sources/CollieDevice/HelperProtocol.swift ;;
  p2) t $D && grep -rq unsupported Sources/CollieDaemonKit/Devices ;;
  p3) t $D && grep -rq symbolAliases Sources/CollieDevice ;;
  *) echo "tarefa desconhecida: $1" >&2; exit 2 ;;
esac
