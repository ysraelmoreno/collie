#!/usr/bin/env bash
# Checks of device loop 10 (docs/superpowers/specs/dl10/*.md): scripts/check-device-loop10.sh i1|i2
set -euo pipefail
cd "$(dirname "$0")/.."
t() { swift test --disable-sandbox --skip MemoryEventEmissionTests "$@"; }
D="--filter DeviceCommandTests --filter SimCommandTests --filter CommandsTests --filter DeviceHelperTests --filter OCRTests --filter ScreenModelTests --filter CollieDeviceTests"
case "${1:?i1|i2}" in
  i1) t --filter OCRTests --filter ScreenModelTests --filter SimCommandTests && grep -q containerAreaMin Sources/CollieDevice/OCR.swift ;;
  i2) t --filter ScreenModelTests --filter CollieDeviceTests && grep -rqi "decorat" Sources/CollieDevice/ScreenModel.swift ;;
  *) echo "tarefa desconhecida: $1" >&2; exit 2 ;;
esac
