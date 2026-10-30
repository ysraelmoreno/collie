#!/bin/sh
# usage: proxy-off.sh <serial> [port]. Restores the saved http_proxy (":0" when there was none) and drops the reverse.
set -eu
S=$1; P=${2:-8899}; ADB=${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}
here=$(cd "$(dirname "$0")" && pwd); prev=$(cat "$here/.mitm/prev-proxy-$S" 2>/dev/null || echo null)
case $prev in null|""|:0) prev=:0;; esac
"$ADB" -s "$S" shell settings put global http_proxy "$prev"
"$ADB" -s "$S" reverse --remove tcp:"$P" 2>/dev/null || true
rm -f "$here/.mitm/prev-proxy-$S"
echo "proxy off: $S http_proxy=$("$ADB" -s "$S" shell settings get global http_proxy)"
