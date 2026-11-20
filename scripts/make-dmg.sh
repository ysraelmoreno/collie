#!/bin/bash
# Builds a DMG whose Finder window shows the app, the Applications link and Resources/dmg-background.tiff
# (design "Tinta": docs/pages/dmg-opcoes). Usage: scripts/make-dmg.sh <Collie.app> <out.dmg>
# The window layout is written by Finder (AppleScript), so it needs a logged-in session. Where Finder can't be driven
# (no GUI, automation denied) the DMG is still built, without the layout, and a warning says so:
# COLLIE_DMG_STRICT=1 makes that an error.
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# = 2 ] || { echo "usage: $0 <Collie.app> <out.dmg>" >&2; exit 1; }
APP="$1" DMG="$2" BG=Resources/dmg-background.tiff
[ -d "$APP" ] || { echo "error: missing $APP" >&2; exit 1; }
[ -f "$BG" ] || { echo "error: missing $BG (run scripts/make-dmg-background.sh)" >&2; exit 1; }
NAME="$(basename "$APP")"
TMP="$(mktemp -d)"; MNT=""
cleanup() { [ -z "$MNT" ] || hdiutil detach "$MNT" -force >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT

mkdir "$TMP/stage" "$TMP/stage/.background"
cp -R "$APP" "$TMP/stage/"; ln -s /Applications "$TMP/stage/Applications"
cp "$BG" "$TMP/stage/.background/background.tiff"
hdiutil create -volname Collie -srcfolder "$TMP/stage" -ov -format UDRW -fs HFS+ "$TMP/rw.dmg" >/dev/null
# the mount point is read back: a second "Collie" volume mounts as "Collie 1"
MNT="$(hdiutil attach "$TMP/rw.dmg" -readwrite -noverify -noautoopen | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)"
[ -d "$MNT" ] || { echo "error: could not mount the image" >&2; exit 1; }
VOL="$(basename "$MNT")"

# 660x420 of content plus the 28 pt title bar; positions are the icons' centres, matching the tags of the background
if osascript - "$VOL" "$NAME" >"$TMP/osa.log" 2>&1 <<'OSA'
on run argv
  set vol to item 1 of argv
  set appName to item 2 of argv
  tell application "Finder"
    tell disk vol
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set bounds of container window to {200, 120, 860, 568}
      set opts to icon view options of container window
      set arrangement of opts to not arranged
      set icon size of opts to 112
      set text size of opts to 13
      set background picture of opts to file ".background:background.tiff"
      set position of item appName of container window to {180, 190}
      set position of item "Applications" of container window to {480, 190}
      close
      open
      update without registering applications
      delay 1
      close
    end tell
  end tell
end run
OSA
then LAYOUT=1
else
  LAYOUT=0
  echo "warning: Finder could not lay out the window ($(tr '\n' ' ' <"$TMP/osa.log" | cut -c1-200)): plain DMG" >&2
  [ "${COLLIE_DMG_STRICT:-}" != 1 ] || exit 1
fi
sync
rm -rf "$MNT/.fseventsd" 2>/dev/null || true
hdiutil detach "$MNT" >/dev/null || hdiutil detach "$MNT" -force >/dev/null
MNT=""
rm -f "$DMG"
hdiutil convert "$TMP/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
[ "$LAYOUT" = 1 ] && echo "ok: $DMG" || echo "ok (no window layout): $DMG"
