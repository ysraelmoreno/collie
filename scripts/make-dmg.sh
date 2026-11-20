#!/bin/bash
# Builds a DMG whose Finder window shows the app, the Applications link and Resources/dmg-background.tiff
# (design "Tinta": docs/pages/dmg-opcoes). Usage: scripts/make-dmg.sh <Collie.app> <out.dmg>
# dmgbuild writes the window layout (.DS_Store) directly: no Finder needed. Setup: pip install -r scripts/dmg-requirements.txt
# Window size and icon positions live in scripts/dmg-settings.py (and only there). Python: $COLLIE_DMG_PYTHON (default python3).
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# = 2 ] || { echo "usage: $0 <Collie.app> <out.dmg>" >&2; exit 1; }
APP="$1" DMG="$2" BG=Resources/dmg-background.tiff PY="${COLLIE_DMG_PYTHON:-python3}"
[ -d "$APP" ] || { echo "error: missing $APP" >&2; exit 1; }
[ -f "$BG" ] || { echo "error: missing $BG (run scripts/make-dmg-background.sh)" >&2; exit 1; }
"$PY" -c 'import dmgbuild, ds_store' 2>/dev/null \
  || { echo "error: dmgbuild not installed for $PY. Install: $PY -m pip install -r scripts/dmg-requirements.txt" >&2; exit 1; }
MNT=""
cleanup() { [ -z "$MNT" ] || hdiutil detach "$MNT" -force >/dev/null 2>&1 || true; }
trap cleanup EXIT

rm -f "$DMG"
"$PY" -m dmgbuild -s scripts/dmg-settings.py -D app="$APP" -D background="$BG" Collie "$DMG" >/dev/null

# Verify: mount read-only and read the .DS_Store back (icon positions, background image).
OUT="$(hdiutil attach "$DMG" -nobrowse -readonly -noautoopen)" || { echo "error: could not mount $DMG" >&2; exit 1; }
MNT="$(awk -F'\t' '/\/Volumes\//{print $NF}' <<<"$OUT" | tail -1)"
[ -d "$MNT" ] || { echo "error: no mount point in hdiutil output: $OUT" >&2; exit 1; }
[ -f "$MNT/.DS_Store" ] || { echo "error: no .DS_Store in the dmg" >&2; exit 1; }
"$PY" -I - "$MNT/.DS_Store" "$(basename "$APP")" scripts/dmg-settings.py <<'PYEOF'
import sys
from ds_store import DSStore
ds, app, settings = sys.argv[1:4]
try:
    d = DSStore.open(ds, "r")
except OSError as e:
    sys.exit(f"error: no readable .DS_Store in the dmg ({e})")
with d:
    entries = {(e.filename, e.code): e.value for e in d}
cfg = {}
exec(open(settings).read(), {"defines": {"app": app, "background": ""}}, cfg)
for item in (app, "Applications"):
    pos = entries.get((item, b"Iloc"))
    if pos is None:
        sys.exit(f"error: .DS_Store has no icon position for {item}")
    print(f"  {item}: Iloc x={pos[0]} y={pos[1]}")
    if (pos[0], pos[1]) != tuple(cfg["icon_locations"][item]):
        sys.exit(f"error: {item} at {pos[:2]}, settings say {cfg['icon_locations'][item]}")
icvp = entries.get((".", b"icvp"))
if not icvp or icvp.get("backgroundType") != 2 or not icvp.get("backgroundImageAlias"):
    sys.exit("error: .DS_Store has no background image (icvp.backgroundType != 2)")
print(f"  background: image alias, {len(icvp['backgroundImageAlias'])} bytes")
PYEOF
hdiutil detach "$MNT" >/dev/null || hdiutil detach "$MNT" -force >/dev/null
MNT=""
echo "ok: $DMG"
