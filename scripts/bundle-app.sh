#!/bin/bash
# Builds build/Collie.app (Collie + collied + collie), ad-hoc signed with hardened runtime. Idempotent.
set -euo pipefail
cd "$(dirname "$0")/.."
# one --product per invocation: repeated flags build only the last
for p in CollieApp collied collie collie-ctty; do swift build -c release --product "$p"; done
BIN="$(swift build -c release --show-bin-path)"
APP=build/Collie.app
rm -rf "$APP"
# collie/collied live in Helpers/: "Collie" and "collie" collide in MacOS/ on case-insensitive APFS
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/CollieApp" "$APP/Contents/MacOS/Collie"
cp "$BIN/collied" "$BIN/collie" "$BIN/collie-ctty" "$APP/Contents/Helpers/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Resources/NOTICE-scrcpy "$APP/Contents/Resources/"
# collied finds it at <Helpers>/../Resources/scrcpy-server; without it device panels show an error instead of video
if [ -f vendor/scrcpy-server ]; then cp vendor/scrcpy-server "$APP/Contents/Resources/scrcpy-server"
else echo "warning: vendor/scrcpy-server missing (run scripts/fetch-scrcpy-server.sh): no device video" >&2; fi
# Bundled fonts: ATSApplicationFontsPath (Info.plist) registers Resources/Fonts; missing = system fonts
cp Resources/NOTICE-fonts "$APP/Contents/Resources/"
if ls vendor/fonts/*.ttf >/dev/null 2>&1; then
  mkdir -p "$APP/Contents/Resources/Fonts"; cp vendor/fonts/*.ttf "$APP/Contents/Resources/Fonts/"
else echo "warning: vendor/fonts missing (run scripts/fetch-fonts.sh): system fonts" >&2; fi
# Design engine (scripts/build-figcraft.sh): helpers + web UI + licences under Resources/figcraft/
cp Resources/NOTICE-figcraft "$APP/Contents/Resources/"
if [ -x vendor/figcraft/bin/figcraft-server ] && [ -f vendor/figcraft/web/index.html ]; then
  mkdir -p "$APP/Contents/Resources/figcraft"
  cp -R vendor/figcraft/bin vendor/figcraft/web vendor/figcraft/licenses "$APP/Contents/Resources/figcraft/"
  # --deep doesn't sign Mach-O under Resources: sign the helpers themselves
  codesign --force -s - --options runtime "$APP/Contents/Resources/figcraft/bin/"*
else echo "warning: vendor/figcraft missing (run scripts/build-figcraft.sh): no design engine" >&2; fi
codesign --force --deep -s - --options runtime "$APP"
codesign -v "$APP"
echo "ok: $APP"
echo "Instalar: copie $APP para /Applications antes do primeiro uso (collied iniciado pelo launchd a partir de ~/Documents, ~/Desktop ou ~/Downloads trava no TCC)."
