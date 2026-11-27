#!/bin/bash
# Offline check of scripts/ci/appcast.sh with a fake dmg, a fake app and a stub sign_update (no real key anywhere).
# Run: scripts/ci/test-appcast.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
A="$PWD/scripts/ci/appcast.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$T/build/Collie.app/Contents" "$T/bin"
APP="$T/build/Collie.app" DMG="$T/build/Collie-0.2.2.dmg" OUT="$T/appcast.xml"
head -c 4096 /dev/urandom > "$DMG"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string 0.2.2 "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string 2002 "$APP/Contents/Info.plist"
# stub: proves the key arrives on stdin (never argv) and the file is the dmg; prints a fixed signature
cat > "$T/bin/sign_update" <<'S'
#!/bin/bash
[ "$1 $2 $3" = "-p -f -" ] || { echo "bad args: $*" >&2; exit 2; }
[ "$(cat)" = "test-private-key" ] || { echo "key not on stdin" >&2; exit 3; }
[ -f "$4" ] || exit 4
echo "c2lnbmF0dXJlLWZvci10ZXN0cw=="
S
chmod +x "$T/bin/sign_update"
export SPARKLE_SIGN_UPDATE="$T/bin/sign_update" SPARKLE_ED_PRIVATE_KEY=test-private-key
run() { "$A" "$@" >/dev/null 2>"$T/err"; }
refused() { local why="$1"; shift; rm -f "$OUT"; if run "$@"; then fail "accepted: $why"; fi; [ ! -e "$OUT" ] || fail "wrote output: $why"; }
x() { xmllint --xpath "$1" "$OUT" 2>/dev/null; }

run v0.2.2 "$DMG" "$APP" "$OUT" || fail "valid: $(cat "$T/err")"
[ "$(x 'string(//*[local-name()="version"])')" = 2002 ] || fail "sparkle:version"
[ "$(x 'string(//*[local-name()="shortVersionString"])')" = 0.2.2 ] || fail "short version"
[ "$(x 'string(//*[local-name()="minimumSystemVersion"])')" = "$(plutil -extract LSMinimumSystemVersion raw -o - "$APP/Contents/Info.plist")" ] || fail "min system"
[ "$(x 'string(//enclosure/@length)')" = "$(stat -f %z "$DMG")" ] || fail "length"
[ "$(x 'string(//enclosure/@url)')" = "https://github.com/ysraelmoreno/collie/releases/download/v0.2.2/Collie-0.2.2.dmg" ] || fail "url"
[ "$(x 'string(//enclosure/@*[local-name()="edSignature"])')" = "c2lnbmF0dXJlLWZvci10ZXN0cw==" ] || fail "signature"

refused "no key" bash -c 'unset SPARKLE_ED_PRIVATE_KEY; exec "$0" "$@"' "$A" v0.2.2 "$DMG" "$APP" "$OUT"
refused "empty key" env SPARKLE_ED_PRIVATE_KEY= "$A" v0.2.2 "$DMG" "$APP" "$OUT"
refused "bad tag" "$A" v0.2 "$DMG" "$APP" "$OUT"
refused "tag != dmg" "$A" v0.2.3 "$DMG" "$APP" "$OUT"
refused "failing signer" env SPARKLE_SIGN_UPDATE=/usr/bin/false "$A" v0.2.2 "$DMG" "$APP" "$OUT"
plutil -replace CFBundleVersion -string 1 "$APP/Contents/Info.plist"
refused "app build number != tag" "$A" v0.2.2 "$DMG" "$APP" "$OUT"
echo "ok: appcast.sh"
