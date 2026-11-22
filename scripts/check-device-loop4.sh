#!/usr/bin/env bash
# Checks of device loop 4 (docs/superpowers/specs/dl4/*.md): scripts/check-device-loop4.sh h2..h5
set -euo pipefail
cd "$(dirname "$0")/.."
t() { swift test --disable-sandbox --skip MemoryEventEmissionTests "$@"; }
D="--filter DeviceCommandTests --filter SimCommandTests --filter CommandsTests --filter DeviceHelperTests"
E=Sources/CollieDaemonKit/Devices
case "${1:?h2..h5}" in
  h2) t --filter HelperProtocolTests --filter DeviceHelperTests $D && test -f Sources/CollieDevice/HelperProtocol.swift && test -f $E/DeviceHelper.swift ;;
  h3) t $D && grep -rq '"helper"' $E ;;
  h4) t $D && grep -rq subscribe $E ;;
  h5) t --filter CollieOrientationTests && grep -q "collie-helper.apk" scripts/bundle-app.sh && grep -q "device helper" Sources/CollieDaemonKit/CollieOrientation.swift ;;
  *) echo "tarefa desconhecida: $1" >&2; exit 2 ;;
esac
