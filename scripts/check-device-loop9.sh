#!/usr/bin/env bash
# Checks of device loop 9 (docs/superpowers/specs/dl9/*.md): scripts/check-device-loop9.sh k1|k1b|k2|k3
set -euo pipefail
cd "$(dirname "$0")/.."
t() { swift test --disable-sandbox --skip MemoryEventEmissionTests "$@"; }
case "${1:?k1|k1b|k2|k3}" in
  k1) bash -n scripts/build-device-helper.sh && scripts/build-device-helper.sh --help | grep -q -- "--release" && scripts/build-device-helper.sh --help | grep -q -- "--genkey" && grep -q "COLLIE_HELPER_KEYSTORE" scripts/build-device-helper.sh ;;
  k1b) t --filter DeviceHelperTests && grep -rq UPDATE_INCOMPATIBLE Sources/CollieDaemonKit/Devices ;;
  k2) bash -n Helpers/android-device/stress-toggle.sh && Helpers/android-device/stress-toggle.sh --help | grep -qi "rodadas\|rounds" ;;
  k3) python3 -m py_compile scripts/android-ocr-eval.py && python3 scripts/test-android-ocr-eval.py && python3 scripts/android-ocr-eval.py --help | grep -q -- "--panel" && python3 -c "import json;json.load(open('Helpers/android-device/corpus.json'))" ;;
  *) echo "tarefa desconhecida: $1" >&2; exit 2 ;;
esac
