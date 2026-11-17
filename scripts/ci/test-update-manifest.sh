#!/bin/bash
# Offline check of scripts/ci/update-manifest.sh with a fake dmg, a fake app and a simulated codesign.
# Run: scripts/ci/test-update-manifest.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
U="$PWD/scripts/ci/update-manifest.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# same layout release.sh leaves: build/Collie.app and build/Collie-<version>.dmg
mkdir -p "$T/build/Collie.app/Contents/Resources" "$T/bin"
APP="$T/build/Collie.app" DMG="$T/build/Collie-0.2.0.dmg"
head -c 4096 /dev/urandom > "$DMG"
sed 's#<key>CFBundleShortVersionString</key><string>[^<]*</string>#<key>CFBundleShortVersionString</key><string>0.2.0</string>#' \
  Resources/Info.plist > "$APP/Contents/Info.plist"
[ "$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")" = 0.2.0 ] || fail "fixture plist"
cp Resources/figcraft-engine.json "$APP/Contents/Resources/"
printf '#!/bin/sh\necho "Identifier=dev.collie.app" >&2\necho "TeamIdentifier=%s" >&2\n' AG8JQAH6YB > "$T/bin/codesign"
chmod +x "$T/bin/codesign"
export CODESIGN="$T/bin/codesign"
run() { "$U" "$@" >/dev/null 2>"$T/err"; }
refused() { local why="$1"; shift; set +e; run "$@"; local rc=$?; set -e; [ $rc != 0 ] || fail "accepted: $why"; [ ! -e "$T/x.json" ] || fail "wrote output: $why"; }

# correct manifest
run v0.2.0 "$DMG" "$APP" "$T/u.json" || fail "valid: $(cat "$T/err")"
M="$T/u.json"
[ "$(jq -r 'keys_unsorted | join(",")' "$M")" = "format,version,tag,dmg,size,sha256,minimumSystemVersion,teamId,figcraftEngine,page" ] || fail "keys"
[ "$(jq -r .format "$M")" = 1 ] && [ "$(jq -r '.format | type' "$M")" = number ] || fail "format"
[ "$(jq -r '"\(.version) \(.tag) \(.dmg)"' "$M")" = "0.2.0 v0.2.0 Collie-0.2.0.dmg" ] || fail "version from tag"
[ "$(jq -r .page "$M")" = "https://github.com/ysraelmoreno/collie/releases/tag/v0.2.0" ] || fail "page"
[ "$(jq -r .minimumSystemVersion "$M")" = "$(plutil -extract LSMinimumSystemVersion raw -o - Resources/Info.plist)" ] || fail "minimumSystemVersion"
[ "$(jq -r .teamId "$M")" = AG8JQAH6YB ] || fail "teamId"
[ "$(jq -r .figcraftEngine "$M")" = "$(jq -r .version Resources/figcraft-engine.json)" ] || fail "figcraftEngine"
# sha256/size are the dmg's
[ "$(jq -r .sha256 "$M")" = "$(shasum -a 256 "$DMG" | cut -d' ' -f1)" ] || fail "sha256"
[ "$(jq -r '.size | type' "$M")" = number ] && [ "$(jq -r .size "$M")" = 4096 ] || fail "size"
# the rules UpdateManifest.decode (plan Task 1) enforces
jq -e '.format == 1 and (.tag | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")) and .tag == "v\(.version)"
  and .dmg == "Collie-\(.version).dmg" and .page == "https://github.com/ysraelmoreno/collie/releases/tag/\(.tag)"
  and .size > 0 and .size <= 500000000 and (.sha256 | test("^[0-9a-f]{64}$"))' "$M" >/dev/null || fail "decoder rules"
[ "$(wc -c < "$M")" -le 65536 ] || fail "over 64 KB"

# another version comes from its own tag
cp "$DMG" "$T/build/Collie-0.10.3.dmg"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.10.3" "$APP/Contents/Info.plist"
run v0.10.3 "$T/build/Collie-0.10.3.dmg" "$APP" "$T/v.json" || fail "0.10.3: $(cat "$T/err")"
[ "$(jq -r '"\(.version) \(.tag) \(.dmg)"' "$T/v.json")" = "0.10.3 v0.10.3 Collie-0.10.3.dmg" ] || fail "0.10.3 fields"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.2.0" "$APP/Contents/Info.plist"

# refusals: nothing is written
refused "bad tag" 0.2.0 "$DMG" "$APP" "$T/x.json"
refused "prerelease tag" v0.2.0-beta "$DMG" "$APP" "$T/x.json"
refused "figcraft tag" figcraft-v0.7.0-c1 "$DMG" "$APP" "$T/x.json"
refused "tag/dmg mismatch" v0.2.1 "$DMG" "$APP" "$T/x.json"
refused "fixed-name copy" v0.2.0 "$T/build/Collie.dmg" "$APP" "$T/x.json"
refused "app version != tag" v0.10.3 "$T/build/Collie-0.10.3.dmg" "$APP" "$T/x.json"
refused "missing dmg" v0.2.0 "$T/build/nope/Collie-0.2.0.dmg" "$APP" "$T/x.json"
refused "missing app" v0.2.0 "$DMG" "$T/build/Nope.app" "$T/x.json"
mv "$APP/Contents/Resources/figcraft-engine.json" "$T/pin"
refused "missing pin" v0.2.0 "$DMG" "$APP" "$T/x.json"
mv "$T/pin" "$APP/Contents/Resources/figcraft-engine.json"
: > "$T/build/Collie-0.2.1.dmg"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.2.1" "$APP/Contents/Info.plist"
refused "empty dmg" v0.2.1 "$T/build/Collie-0.2.1.dmg" "$APP" "$T/x.json"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.2.0" "$APP/Contents/Info.plist"
printf '#!/bin/sh\necho "TeamIdentifier=XXXXXXXXXX" >&2\n' > "$T/bin/codesign"
refused "team != pin team" v0.2.0 "$DMG" "$APP" "$T/x.json"
printf '#!/bin/sh\necho "TeamIdentifier=not set" >&2\n' > "$T/bin/codesign"
refused "unsigned app" v0.2.0 "$DMG" "$APP" "$T/x.json"
echo "ok: update-manifest.sh"
