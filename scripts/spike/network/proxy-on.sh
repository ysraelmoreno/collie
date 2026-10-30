#!/bin/sh
# usage: proxy-on.sh <serial> [port]. Saves the device's current http_proxy so proxy-off.sh puts it back.
set -eu
S=$1; P=${2:-8899}; ADB=${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}
case $S in emulator-*) ;; *) echo "spike: emulators only" >&2; exit 2;; esac
here=$(cd "$(dirname "$0")" && pwd); mkdir -p "$here/.mitm"
"$ADB" -s "$S" shell settings get global http_proxy > "$here/.mitm/prev-proxy-$S"
"$ADB" -s "$S" reverse tcp:"$P" tcp:"$P"
"$ADB" -s "$S" shell settings put global http_proxy 127.0.0.1:"$P"
echo "proxy on: $S -> 127.0.0.1:$P (was $(cat "$here/.mitm/prev-proxy-$S"))"
