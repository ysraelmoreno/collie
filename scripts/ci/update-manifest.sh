#!/bin/bash
# Writes the update.json the app's updater reads (format 1, spec docs/superpowers/specs/2026-11-17-update-downloader-design.md §1).
# Usage: scripts/ci/update-manifest.sh <tag vX.Y.Z> <dmg Collie-X.Y.Z.dmg> <Collie.app> <out.json>
# Run it on the dmg AFTER notarization and stapling: sha256/size are of that exact file.
# teamId comes from `codesign -dv` of the app (CODESIGN overrides the binary, for the offline test);
# minimumSystemVersion from the app's Info.plist; figcraftEngine from the pin the app ships.
set -euo pipefail
[ $# = 4 ] || { echo "usage: $0 <tag> <dmg> <app> <out>" >&2; exit 1; }
TAG="$1" DMG="$2" APP="$3" OUT="$4"
REPO=https://github.com/ysraelmoreno/collie
die() { echo "update-manifest: $*" >&2; exit 1; }

[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "tag \"$TAG\" is not vX.Y.Z"
VER="${TAG#v}"
NAME="Collie-$VER.dmg"
[ "$(basename "$DMG")" = "$NAME" ] || die "dmg \"$(basename "$DMG")\" is not $NAME"
[ -f "$DMG" ] || die "missing $DMG"
PLIST="$APP/Contents/Info.plist" PIN="$APP/Contents/Resources/figcraft-engine.json"
[ -f "$PLIST" ] || die "missing $PLIST"
[ -f "$PIN" ] || die "missing $PIN"

plist() { plutil -extract "$1" raw -o - "$PLIST" 2>/dev/null || die "$PLIST: no $1"; }
[ "$(plist CFBundleShortVersionString)" = "$VER" ] || die "app version $(plist CFBundleShortVersionString) != $VER"
MINSYS="$(plist LSMinimumSystemVersion)"
[[ "$MINSYS" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || die "LSMinimumSystemVersion \"$MINSYS\""

TEAM="$("${CODESIGN:-codesign}" -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || die "app TeamIdentifier \"$TEAM\" (not signed by a team?)"
PINTEAM="$(jq -r .teamId "$PIN")"
[ "$TEAM" = "$PINTEAM" ] || die "app team $TEAM != pin team $PINTEAM"
ENGINE="$(jq -r .version "$PIN")"
[ -n "$ENGINE" ] && [ "$ENGINE" != null ] || die "$PIN: no version"

SIZE="$(stat -f %z "$DMG")"
(( SIZE > 0 && SIZE <= 500000000 )) || die "dmg size $SIZE out of (0, 500000000]"
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
[[ "$SHA" =~ ^[0-9a-f]{64}$ ]] || die "sha256 \"$SHA\""

jq -n --indent 2 --arg v "$VER" --arg t "$TAG" --arg d "$NAME" --argjson s "$SIZE" --arg h "$SHA" \
  --arg m "$MINSYS" --arg team "$TEAM" --arg e "$ENGINE" --arg p "$REPO/releases/tag/$TAG" \
  '{format: 1, version: $v, tag: $t, dmg: $d, size: $s, sha256: $h, minimumSystemVersion: $m,
    teamId: $team, figcraftEngine: $e, page: $p}' > "$OUT"
echo "ok: $OUT ($NAME, $SIZE bytes, sha256 $SHA)"
