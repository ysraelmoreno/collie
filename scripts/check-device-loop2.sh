#!/usr/bin/env bash
# Checks of the device loop 2 tasks (docs/superpowers/specs/2026-11-22-device-screen-find-design.md): scripts/check-device-loop2.sh l0 e1 .. e5 e3a e3b
set -euo pipefail
cd "$(dirname "$0")/.."
t() { swift test --disable-sandbox --skip MemoryEventEmissionTests "$@"; }
A=Sources/CollieDaemonKit/Devices/DeviceService+Android.swift
P=Sources/CollieProtocol/Plugins.swift
D="--filter DeviceCommandTests --filter SimCommandTests --filter CommandsTests"
case "${1:?l0 e1..e5}" in
  l0) t --filter DeviceCommandTests && grep -q "query-activities" $A ;;
  e1) t --filter ScreenModelTests --filter CollieDeviceTests $D && test -f Sources/CollieDevice/ScreenModel.swift && grep -rq ScreenModelTests Tests ;;
  e2) t $D && grep -q 'dcmd("wait"' $P ;;
  e3a) t $D && grep -q 'dcmd("find"' $P ;;
  e3b) t $D && grep -rq endReached Sources/CollieDaemonKit/Devices ;;
  e4) t $D && grep -q "/dev/tty" $A && grep -q "timingMs" $A ;;
  e5) t --filter CollieOrientationTests && grep -q "device screen" Sources/CollieDaemonKit/CollieOrientation.swift ;;
  *) echo "tarefa desconhecida: $1" >&2; exit 2 ;;
esac
