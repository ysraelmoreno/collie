#!/usr/bin/env bash
# Checks of device loop 7 (docs/superpowers/specs/dl7/*.md): scripts/check-device-loop7.sh a1|a2|a3|a4
set -euo pipefail
cd "$(dirname "$0")/.."
t() { swift test --disable-sandbox --skip MemoryEventEmissionTests "$@"; }
D="--filter DeviceCommandTests --filter SimCommandTests --filter CommandsTests --filter DeviceHelperTests --filter OCRTests --filter ScreenModelTests --filter CollieDeviceTests"
E=Sources/CollieDaemonKit/Devices
case "${1:?a1..a4}" in
  a1) t --filter DeviceHelperTests && grep -rq retrySchedule $E ;;
  a2) t --filter ScreenModelTests --filter CollieDeviceTests && grep -rq symbolNameNoise Sources/CollieDevice ;;
  a3) t $D && grep -q ocrMs $E/DeviceService+iOS.swift ;;
  a4) t --filter OCRTests --filter ScreenModelTests && grep -q opaqueClasses Sources/CollieDevice/OCR.swift && grep -q coverageMin Sources/CollieDevice/OCR.swift ;;
  *) echo "tarefa desconhecida: $1" >&2; exit 2 ;;
esac
