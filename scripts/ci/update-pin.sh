#!/bin/bash
# Writes sha256, size and unpackedSize of a verified figcraft asset into the pin, keeping every other field and the
# format (jq, 2 spaces, key order). Used by figcraft.yml (scripts/ci/pin-pr.sh); test: scripts/ci/test-update-pin.sh.
#   update-pin.sh <pin.json> <version> <sha256> <size> <unpackedSize> [--fresh]
# stdout: "changed" (file rewritten) or "unchanged". Exit 1: bad arguments or the pin is for another version.
# Exit 3: the pin already holds other values (a published version is immutable); --fresh (this run published
# <version> just now, so filled values are stale leftovers of an older version) overwrites them with a warning.
set -euo pipefail
[ "$#" -ge 5 ] || { echo "usage: $0 <pin.json> <version> <sha256> <size> <unpackedSize> [--fresh]" >&2; exit 1; }
PIN="$1" VERSION="$2" SHA="$3" SIZE="$4" UNPACKED="$5" FRESH="${6:-}"
ZERO=0000000000000000000000000000000000000000000000000000000000000000
[[ "$SHA" =~ ^[0-9a-f]{64}$ ]] && [ "$SHA" != "$ZERO" ] || { echo "error: bad sha256 \"$SHA\"" >&2; exit 1; }
[[ "$SIZE" =~ ^[1-9][0-9]*$ ]] && [[ "$UNPACKED" =~ ^[1-9][0-9]*$ ]] || { echo "error: bad size/unpackedSize \"$SIZE\" \"$UNPACKED\"" >&2; exit 1; }
[ -z "$FRESH" ] || [ "$FRESH" = --fresh ] || { echo "error: unknown option $FRESH" >&2; exit 1; }

cur="$(jq -r '[.version, .sha256, .size, .unpackedSize] | @tsv' "$PIN")"
IFS=$'\t' read -r pv psha psize punpacked <<<"$cur"
[ "$pv" = "$VERSION" ] || { echo "error: pin is for $pv, the asset for $VERSION" >&2; exit 1; }
if [ "$psha" = "$SHA" ] && [ "$psize" = "$SIZE" ] && [ "$punpacked" = "$UNPACKED" ]; then echo unchanged; exit 0; fi
if [ "$psha" != "$ZERO" ]; then
  [ -n "$FRESH" ] || { echo "error: pin $pv already holds sha256=$psha size=$psize unpackedSize=$punpacked, the asset has sha256=$SHA size=$SIZE unpackedSize=$UNPACKED: not overwriting" >&2; exit 3; }
  echo "warning: $pv was published just now: overwriting stale values sha256=$psha size=$psize unpackedSize=$punpacked" >&2
fi
tmp="$(mktemp "$PIN.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
jq --indent 2 --arg sha "$SHA" --argjson size "$SIZE" --argjson unpacked "$UNPACKED" \
  '.sha256 = $sha | .size = $size | .unpackedSize = $unpacked' "$PIN" > "$tmp"
mv "$tmp" "$PIN"
echo changed
