#!/usr/bin/env bash
# Checks of device loop 11 (docs/superpowers/specs/dl11/*.md): scripts/check-device-loop11.sh s1|s2
set -euo pipefail
cd "$(dirname "$0")/.."
t() { swift test --disable-sandbox --skip MemoryEventEmissionTests "$@"; }
case "${1:?s1|s2}" in
  s1) t --filter DeviceHelperTests && grep -q sha256 Sources/CollieDaemonKit/Devices/DeviceHelper.swift ;;
  s2) bash -n scripts/verify-device-helper.sh && scripts/verify-device-helper.sh --help | grep -q -- "--print" && scripts/test-verify-device-helper.sh && grep -q verify-device-helper scripts/release.sh && test -s Resources/collie-helper.cert.sha256 ;;
  *) echo "tarefa desconhecida: $1" >&2; exit 2 ;;
esac
