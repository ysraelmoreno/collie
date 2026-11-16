#!/bin/bash
# Builds a distributable build/Collie-<version>.dmg: Developer ID signed, notarized, stapled.
# Needs (paid Apple Developer Program):
#   1. "Developer ID Application" cert in the login keychain (see docs/release.md)
#   2. notarytool credentials stored once:
#        xcrun notarytool store-credentials collie-notary --apple-id <id> --team-id <TEAMID> --password <app-specific-password>
# Env: COLLIE_SIGN_IDENTITY (default: first "Developer ID Application" found), COLLIE_NOTARY_PROFILE (default collie-notary)
# COLLIE_SKIP_NOTARIZE=1 signs and builds the dmg only (check the signing without Apple).
set -euo pipefail
cd "$(dirname "$0")/.."
PROFILE="${COLLIE_NOTARY_PROFILE:-collie-notary}"
IDS="$(security find-identity -v -p codesigning || true)"
ID="${COLLIE_SIGN_IDENTITY:-$(sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' <<<"$IDS" | head -1)}"
[ -n "$ID" ] || { echo "error: no \"Developer ID Application\" identity in keychain (docs/release.md)" >&2; exit 1; }
grep -qF "\"$ID\"" <<<"$IDS" || { echo "error: identity \"$ID\" not in keychain" >&2; exit 1; }
case "$ID" in "Developer ID Application:"*) ;; *) echo "error: \"$ID\" is not a Developer ID Application identity: Gatekeeper rejects it on other Macs" >&2; exit 1;; esac

COLLIE_SIGN_IDENTITY="$ID" COLLIE_TIMESTAMP=1 scripts/bundle-app.sh
APP=build/Collie.app
codesign --verify --deep --strict --verbose=2 "$APP"
# notarization rejects binaries without hardened runtime or secure timestamp: fail here, not after the upload
bad=0
while IFS= read -r f; do
  if file "$f" | grep -q Mach-O; then
    d="$(codesign -dvv "$f" 2>&1)"
    grep -q 'flags=.*runtime' <<<"$d" && grep -q '^Timestamp=' <<<"$d" || { echo "error: not hardened+timestamped: $f" >&2; bad=1; }
  fi
done < <(find "$APP" -type f)
[ "$bad" = 0 ] || exit 1

VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
DMG="build/Collie-$VER.dmg"
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname Collie -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force -s "$ID" --timestamp "$DMG"

if [ "${COLLIE_SKIP_NOTARIZE:-}" = 1 ]; then echo "ok (not notarized): $DMG"; exit 0; fi
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait   # prints the log id on Invalid: notarytool log <id> --keychain-profile $PROFILE
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"
echo "ok: $DMG"
