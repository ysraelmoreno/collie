#!/usr/bin/env bash
# Checks of device loop 5, the OCR fallback (docs/superpowers/specs/dl5/*.md): scripts/check-device-loop5.sh h6a|h6b|h6c
set -euo pipefail
cd "$(dirname "$0")/.."
t() { swift test --disable-sandbox --skip MemoryEventEmissionTests "$@"; }
D="--filter DeviceCommandTests --filter SimCommandTests --filter CommandsTests --filter DeviceHelperTests --filter OCRTests"
E=Sources/CollieDaemonKit/Devices
case "${1:?h6a|h6b|h6c}" in
  h6a) t --filter OCRTests --filter CollieDeviceTests && test -f Sources/CollieDevice/OCR.swift ;;
  h6b) t $D && test -f $E/VisionOCR.swift && grep -rq '"ocr"' $E ;;
  h6c) t $D --filter CollieOrientationTests && grep -rq ocrMs $E ;;
  *) echo "tarefa desconhecida: $1" >&2; exit 2 ;;
esac
