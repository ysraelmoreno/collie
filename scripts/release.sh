#!/bin/bash
# Builds a distributable build/Collie-<version>.dmg: Developer ID signed, notarized, stapled.
# Needs (paid Apple Developer Program):
#   1. "Developer ID Application" cert in the login keychain (see docs/release.md)
#   2. notarytool credentials, either stored once in the keychain:
#        xcrun notarytool store-credentials collie-notary --apple-id <id> --team-id <TEAMID> --password <app-specific-password>
#      or an App Store Connect API key (CI): COLLIE_NOTARY_KEY=<path to AuthKey_XXX.p8> COLLIE_NOTARY_KEY_ID COLLIE_NOTARY_ISSUER
# Env: COLLIE_SIGN_IDENTITY (default: first "Developer ID Application" found), COLLIE_NOTARY_PROFILE (default collie-notary)
# COLLIE_VERSION=1.2.3 (or v1.2.3, e.g. the tag) overrides CFBundleShortVersionString in the app and the dmg name.
# COLLIE_NOTARY_TIMEOUT: seconds to wait for Apple (default 14400); the wait polls, a network blip doesn't abort it.
# COLLIE_SKIP_NOTARIZE=1 signs and builds the dmg only (check the signing without Apple).
set -euo pipefail
cd "$(dirname "$0")/.."
PROFILE="${COLLIE_NOTARY_PROFILE:-collie-notary}"
if [ -n "${COLLIE_NOTARY_KEY:-}" ]; then
  : "${COLLIE_NOTARY_KEY_ID:?COLLIE_NOTARY_KEY needs COLLIE_NOTARY_KEY_ID}" "${COLLIE_NOTARY_ISSUER:?COLLIE_NOTARY_KEY needs COLLIE_NOTARY_ISSUER}"
  AUTH=(--key "$COLLIE_NOTARY_KEY" --key-id "$COLLIE_NOTARY_KEY_ID" --issuer "$COLLIE_NOTARY_ISSUER")
else AUTH=(--keychain-profile "$PROFILE"); fi
V="${COLLIE_VERSION:-}"; export COLLIE_VERSION="${V#v}"   # bundle-app.sh writes it into the app's Info.plist
if [ -n "$COLLIE_VERSION" ] && ! [[ "$COLLIE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: COLLIE_VERSION \"$COLLIE_VERSION\" is not X.Y.Z" >&2; exit 1
fi
IDS="$(security find-identity -v -p codesigning || true)"
ID="${COLLIE_SIGN_IDENTITY:-$(sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' <<<"$IDS" | head -1)}"
[ -n "$ID" ] || { echo "error: no \"Developer ID Application\" identity in keychain (docs/release.md)" >&2; exit 1; }
grep -qF "\"$ID\"" <<<"$IDS" || { echo "error: identity \"$ID\" not in keychain" >&2; exit 1; }
case "$ID" in "Developer ID Application:"*) ;; *) echo "error: \"$ID\" is not a Developer ID Application identity: Gatekeeper rejects it on other Macs" >&2; exit 1;; esac

# release builds never embed figcraft: the app downloads the engine Resources/figcraft-engine.json pins
COLLIE_BUNDLE_FIGCRAFT=0 COLLIE_SIGN_IDENTITY="$ID" COLLIE_TIMESTAMP=1 scripts/bundle-app.sh
APP=build/Collie.app
[ ! -e "$APP/Contents/Resources/figcraft" ] || { echo "error: $APP/Contents/Resources/figcraft exists: release builds don't embed the design engine" >&2; exit 1; }
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

VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/Collie-$VER.dmg"
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname Collie -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force -s "$ID" --timestamp "$DMG"

if [ "${COLLIE_SKIP_NOTARIZE:-}" = 1 ]; then echo "ok (not notarized): $DMG"; exit 0; fi
# no --wait: Apple can take over an hour and --wait dies on a network timeout; poll instead
SUB="$(xcrun notarytool submit "$DMG" "${AUTH[@]}" --output-format json | plutil -extract id raw -o - -)"
echo "notarization id: $SUB (xcrun notarytool info|log $SUB <credentials>)"
deadline=$((SECONDS + ${COLLIE_NOTARY_TIMEOUT:-14400}))
while :; do
  j="$(xcrun notarytool info "$SUB" "${AUTH[@]}" --output-format json 2>/dev/null)" || j=""
  st="$(plutil -extract status raw -o - - <<<"$j" 2>/dev/null)" || st="unknown (network?)"
  case "$st" in
    Accepted) break ;;
    Invalid|Rejected) xcrun notarytool log "$SUB" "${AUTH[@]}" >&2 || true; echo "error: notarization $st ($SUB)" >&2; exit 1 ;;
  esac
  [ "$SECONDS" -lt "$deadline" ] || { echo "error: notarization $SUB still $st after ${COLLIE_NOTARY_TIMEOUT:-14400}s" >&2; exit 1; }
  echo "notarization: $st ($((SECONDS / 60)) min)"; sleep 60
done
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"
echo "ok: $DMG"
