#!/bin/bash
# Writes the Sparkle appcast.xml for one release (spec docs/superpowers/specs/2026-11-25-sparkle-updater-design.md §5).
# Usage: scripts/ci/appcast.sh <tag vX.Y.Z> <dmg Collie-X.Y.Z.dmg> <Collie.app> <out.xml>
# Run it on the dmg AFTER notarization and stapling: the EdDSA signature and length are of that exact file.
# SPARKLE_ED_PRIVATE_KEY (the secret) goes to sign_update by stdin, never argv or a file; SPARKLE_SIGN_UPDATE is the path of
# Sparkle's sign_update (default: sign_update in PATH).
set -euo pipefail
set +x
[ $# = 4 ] || { echo "usage: $0 <tag> <dmg> <app> <out>" >&2; exit 1; }
TAG="$1" DMG="$2" APP="$3" OUT="$4"
REPO=https://github.com/ysraelmoreno/collie
die() { echo "appcast: $*" >&2; exit 1; }

[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ] || die "SPARKLE_ED_PRIVATE_KEY is empty: an appcast is never published unsigned"
BUILD="$("$(dirname "$0")/build-number.sh" "$TAG")" || exit 1
VER="${TAG#v}"
NAME="Collie-$VER.dmg"
[ "$(basename "$DMG")" = "$NAME" ] || die "dmg \"$(basename "$DMG")\" is not $NAME"
[ -f "$DMG" ] || die "missing $DMG"
PLIST="$APP/Contents/Info.plist"
[ -f "$PLIST" ] || die "missing $PLIST"
plist() { plutil -extract "$1" raw -o - "$PLIST" 2>/dev/null || die "$PLIST: no $1"; }
[ "$(plist CFBundleShortVersionString)" = "$VER" ] || die "app version $(plist CFBundleShortVersionString) != $VER"
[ "$(plist CFBundleVersion)" = "$BUILD" ] || die "app CFBundleVersion $(plist CFBundleVersion) != $BUILD"
MINSYS="$(plist LSMinimumSystemVersion)"
[[ "$MINSYS" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || die "LSMinimumSystemVersion \"$MINSYS\""

SIZE="$(stat -f %z "$DMG")"
(( SIZE > 0 )) || die "empty $DMG"
SIG="$("${SPARKLE_SIGN_UPDATE:-sign_update}" -p -f - "$DMG" <<<"$SPARKLE_ED_PRIVATE_KEY")" || die "sign_update failed"
[[ "$SIG" =~ ^[A-Za-z0-9+/]+=*$ ]] || die "sign_update gave no signature"

TMP="$(mktemp "$OUT.XXXXXX")"
cat > "$TMP" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Collie</title>
    <item>
      <title>Collie $VER</title>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VER</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINSYS</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$REPO/releases/tag/$TAG</sparkle:fullReleaseNotesLink>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <enclosure url="$REPO/releases/download/$TAG/$NAME" length="$SIZE" type="application/octet-stream" sparkle:edSignature="$SIG"/>
    </item>
  </channel>
</rss>
XML
xmllint --noout "$TMP" || { rm -f "$TMP"; die "generated XML is not well-formed"; }
mv "$TMP" "$OUT"
