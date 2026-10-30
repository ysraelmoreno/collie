#!/bin/sh
# usage: ca.sh <serial> inject <ca.pem> | ca.sh <serial> eject. Emulators only; needs a rootable image (google_apis).
set -eu
S=$1; ADB=${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}; O=${OPENSSL:-/opt/homebrew/opt/openssl@3/bin/openssl}
case $S in emulator-*) ;; *) echo "spike: emulators only" >&2; exit 2;; esac
here=$(cd "$(dirname "$0")" && pwd)
"$ADB" -s "$S" root >/dev/null; "$ADB" -s "$S" wait-for-device
"$ADB" -s "$S" shell mkdir -p /data/local/tmp/collie-ca
"$ADB" -s "$S" push -q "$here/ca-device.sh" /data/local/tmp/collie-ca/ca-device.sh
if [ "$2" = inject ]; then
  h=$("$O" x509 -in "$3" -noout -subject_hash_old)
  "$O" x509 -in "$3" -outform PEM > "$here/.mitm/$h.0"   # PEM only: the cert, never the key
  "$ADB" -s "$S" push -q "$here/.mitm/$h.0" "/data/local/tmp/collie-ca/$h.0"; rm "$here/.mitm/$h.0"
  "$ADB" -s "$S" shell sh /data/local/tmp/collie-ca/ca-device.sh inject "$h.0"
else
  "$ADB" -s "$S" shell sh /data/local/tmp/collie-ca/ca-device.sh eject
fi
