#!/bin/bash
# Checks that the helper APK is signed with the publisher's key: the SHA-256 of its signing certificate must equal the pin in
# Resources/collie-helper.cert.sha256 (one line, lowercase hex, no colons). scripts/release.sh runs it before packaging.
# Usage: scripts/verify-device-helper.sh [--print] [apk]   (apk default Resources/collie-helper.apk)
#   --print  prints the APK's certificate SHA-256 (to write into the pin file) and exits.
# apksigner: PATH first, then $ANDROID_HOME or ~/Library/Android/sdk, latest build-tools. Java: JAVA_HOME, else the Android Studio JBR.
# Exit: 0 match, 1 mismatch, 2 apksigner, APK or pin missing (or apksigner could not read the APK). COLLIE_HELPER_PIN overrides the pin path.
set -euo pipefail
cd "$(dirname "$0")/.."
PRINT=0
case "${1:-}" in
  -h|--help) sed -n '2,7s/^# \{0,1\}//p' "$0"; exit 0 ;;
  --print) PRINT=1; shift ;;
esac
APK="${1:-Resources/collie-helper.apk}"
PIN="${COLLIE_HELPER_PIN:-Resources/collie-helper.cert.sha256}"
[ -f "$APK" ] || { echo "error: APK $APK não existe" >&2; exit 2; }
SIGNER="$(command -v apksigner || true)"
if [ -z "$SIGNER" ]; then
  SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
  if [ -d "$SDK/build-tools" ]; then
    BT="$(ls "$SDK/build-tools" | sort -V | tail -1)"
    [ -n "$BT" ] && [ -x "$SDK/build-tools/$BT/apksigner" ] && SIGNER="$SDK/build-tools/$BT/apksigner"
  fi
fi
[ -n "$SIGNER" ] || { echo "error: apksigner não encontrado (PATH, \$ANDROID_HOME ou ~/Library/Android/sdk/build-tools); instale o Android SDK ou defina ANDROID_HOME" >&2; exit 2; }
JBR="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
if [ -z "${JAVA_HOME:-}" ] && [ -d "$JBR" ]; then export JAVA_HOME="$JBR"; fi
[ -n "${JAVA_HOME:-}" ] && export PATH="$JAVA_HOME/bin:$PATH"
OUT="$("$SIGNER" verify --print-certs "$APK" 2>&1)" || { echo "error: apksigner verify falhou em $APK:" >&2; echo "$OUT" >&2; exit 2; }
# ponytail: first signer only; a multi-signer APK (key rotation) would need every line compared
GOT="$(sed -n 's/.*certificate SHA-256 digest: *\([0-9a-fA-F:]*\).*/\1/p' <<<"$OUT" | head -1 | tr -d ':' | tr 'A-F' 'a-f')"
[ -n "$GOT" ] || { echo "error: apksigner não imprimiu o SHA-256 do certificado de $APK:" >&2; echo "$OUT" >&2; exit 2; }
if [ "$PRINT" = 1 ]; then echo "$GOT"; exit 0; fi
[ -s "$PIN" ] || { echo "error: arquivo de pino $PIN não existe ou está vazio (grave nele a saída de scripts/verify-device-helper.sh --print)" >&2; exit 2; }
WANT="$(head -1 "$PIN" | tr -d ' :\r\t' | tr 'A-F' 'a-f')"
if [ "$GOT" != "$WANT" ]; then
  echo "error: $APK assinado com outra chave ou com a chave debug" >&2
  echo "  certificado do APK: $GOT" >&2
  echo "  pino ($PIN):        $WANT" >&2
  exit 1
fi
echo "ok: $APK assinado com a chave do pino ($GOT)"
