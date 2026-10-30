#!/bin/sh
# Points an Android emulator at the local mitmdump and makes it trust the mitm CA; undoes it. Idempotent: attach on an
# attached device repairs what is missing (e.g. the adb reverse after a reconnect), detach on a clean one is a no-op.
# Reference for DeviceSetup (Swift): the steps, in order, with the output each one expects, are in README.md.
#
#   netsetup.sh attach <serial> [port] [ca.pem]   default port 8899, ca .mitm/mitmproxy-ca-cert.pem
#   netsetup.sh detach <serial> [port]
#   netsetup.sh status <serial> [port]
#
# Emulators only. Needs a rootable image (google_apis / AOSP; google_apis_playstore refuses adb root).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
ADB=${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}
OPENSSL=${OPENSSL:-/opt/homebrew/opt/openssl@3/bin/openssl}
cmd=${1:-}; S=${2:-}; P=${3:-8899}; CA=${4:-$here/.mitm/mitmproxy-ca-cert.pem}
ST=/data/local/tmp/collie-ca
ours="127.0.0.1:$P"

die() { echo "error: $*" >&2; exit 1; }
adb() { "$ADB" -s "$S" "$@"; }
sh_() { adb shell "$@" | tr -d '\r'; }
case $S in emulator-*) ;; *) die "usage: $0 attach|detach|status emulator-NNNN [port] [ca.pem] (emulators only)";; esac
[ "$("$ADB" -s "$S" get-state 2>/dev/null)" = device ] || die "$S is not an online device"

# adb root restarts adbd when it is not root yet, and that drops every adb reverse: always root before reversing.
root() {
  out=$(adb root 2>&1 | tr -d '\r')     # "restarting adbd as root" | "adbd is already running as root"
  case $out in *"cannot run as root"*) die "image not rootable ($out)";; esac
  adb wait-for-device
  [ "$(sh_ id -u)" = 0 ] || die "adbd is not root after adb root"
  echo "root: ${out:-ok}"
}
device() { sh_ sh $ST/netsetup-device.sh "$@"; }
push_script() { adb shell mkdir -p $ST; adb push -q "$here/netsetup-device.sh" $ST/netsetup-device.sh; }

case $cmd in
attach)
  [ -f "$CA" ] || die "no CA at $CA (start mitm.sh once to generate it)"
  root
  echo "sdk: $(sh_ getprop ro.build.version.sdk)"
  # Android looks CAs up by OpenSSL's old subject hash: the file must be named <hash>.0 and hold only the cert (PEM)
  H=$("$OPENSSL" x509 -in "$CA" -noout -subject_hash_old)
  push_script
  "$OPENSSL" x509 -in "$CA" -outform PEM | adb shell "cat > $ST/$H.0"
  device inject "$H"
  # proxy: remember what was there (another tool's proxy, or nothing) once; a second attach must not save our own value
  cur=$(sh_ settings get global http_proxy)
  if [ "$cur" != "$ours" ]; then sh_ "echo '$cur' > $ST/prev-proxy"; fi
  sh_ settings put global http_proxy "$ours"
  echo "proxy: $ours (was $(sh_ cat $ST/prev-proxy 2>/dev/null || echo '?'))"
  adb reverse tcp:"$P" tcp:"$P" >/dev/null     # replaces an existing rule for the same port
  adb reverse --list | grep -q "tcp:$P tcp:$P" && echo "reverse: tcp:$P" || die "adb reverse did not stick"
  nc -z 127.0.0.1 "$P" 2>/dev/null && echo "host: mitmdump listening on $ours" || echo "host: WARNING nothing listens on $ours (run mitm.sh)"
  echo "attached $S" ;;
detach)
  root
  # proxy first: only put back the previous value when the current one is ours (never clobber another tool's proxy)
  cur=$(sh_ settings get global http_proxy)
  prev=$(sh_ cat $ST/prev-proxy 2>/dev/null || true)
  case $prev in ""|null|*"No such file"*) prev=:0;; esac   # ":0" clears at once; "delete" only takes effect after a reboot
  if [ "$cur" = "$ours" ]; then sh_ settings put global http_proxy "$prev"; echo "proxy: restored $prev"; else echo "proxy: left $cur"; fi
  adb reverse --remove tcp:"$P" >/dev/null 2>&1 && echo "reverse: removed" || echo "reverse: absent"
  if [ "$(sh_ "[ -f $ST/hash ] && echo y")" = y ] || [ "$(sh_ "grep -c '^collie-ca ' /proc/mounts")" != 0 ]; then
    push_script; device eject
  else
    echo "ca: absent"
  fi
  echo "detached $S" ;;
status)
  echo "root: $([ "$(sh_ id -u)" = 0 ] && echo yes || echo no)  sdk: $(sh_ getprop ro.build.version.sdk)"
  cur=$(sh_ settings get global http_proxy); rev=$(adb reverse --list | grep -c "tcp:$P tcp:$P" || true)
  echo "proxy: $cur  reverse: $([ "$rev" -gt 0 ] && echo yes || echo no)"
  # after a reboot or an adbd restart the proxy setting survives but the reverse does not: the device has no network
  if [ "$cur" = "$ours" ] && [ "$rev" = 0 ]; then echo "ORPHAN: http_proxy points at $ours but there is no reverse (attach again or detach)"; fi
  if [ "$(sh_ id -u)" = 0 ] && [ "$(sh_ "[ -f $ST/netsetup-device.sh ] && echo y")" = y ]; then device status; elif [ "$(sh_ id -u)" = 0 ]; then echo "ca: none"; else echo "ca: $(sh_ "[ -f $ST/hash ] && echo staged || echo none") (root needed for detail)"; fi ;;
*) die "usage: $0 attach|detach|status <serial> [port] [ca.pem]" ;;
esac
