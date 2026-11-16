#!/bin/bash
# Packages vendor/figcraft (scripts/build-figcraft.sh) as the downloadable engine of Resources/figcraft-engine.json:
# signs bin/* (Developer ID Application, hardened runtime, timestamp, identifiers figcraft-server / figcraft-cli),
# checks them against the pin's team requirement, notarizes them (zip of bin/: no ticket staples to a loose Mach-O)
# and writes build/figcraft-<version>-arm64.tar.gz + .sha256 (figcraft/{bin,web,licenses,NOTICE-figcraft,engine.json}).
# Usage: scripts/package-figcraft.sh "<Developer ID Application: Name (TEAMID)>"
# Notary credentials, COLLIE_NOTARY_TIMEOUT and COLLIE_SKIP_NOTARIZE=1: as scripts/release.sh.
# stdout carries only sha256=, size=, unpackedSize= (for the pin and $GITHUB_OUTPUT); everything else goes to stderr.
set -euo pipefail
cd "$(dirname "$0")/.."
exec 3>&1 1>&2
ID="${1:?usage: scripts/package-figcraft.sh <sign-identity>}"
PIN=Resources/figcraft-engine.json
pin() { plutil -extract "$1" raw -o - "$PIN"; }
VERSION="$(pin version)"; COMMIT="$(pin commit)"; TEAM="$(pin teamId)"
SRC=vendor/figcraft
for f in bin/figcraft-server bin/figcraft-cli web/index.html licenses; do
  [ -e "$SRC/$f" ] || { echo "error: $SRC/$f missing (scripts/build-figcraft.sh)" >&2; exit 1; }
done
PROFILE="${COLLIE_NOTARY_PROFILE:-collie-notary}"
if [ -n "${COLLIE_NOTARY_KEY:-}" ]; then
  : "${COLLIE_NOTARY_KEY_ID:?COLLIE_NOTARY_KEY needs COLLIE_NOTARY_KEY_ID}" "${COLLIE_NOTARY_ISSUER:?COLLIE_NOTARY_KEY needs COLLIE_NOTARY_ISSUER}"
  AUTH=(--key "$COLLIE_NOTARY_KEY" --key-id "$COLLIE_NOTARY_KEY_ID" --issuer "$COLLIE_NOTARY_ISSUER")
else AUTH=(--keychain-profile "$PROFILE"); fi

STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
E="$STAGE/figcraft"
mkdir "$E"
cp -R "$SRC/bin" "$SRC/web" "$SRC/licenses" "$E/"
cp Resources/NOTICE-figcraft "$E/"
printf '{"version":"%s","commit":"%s"}\n' "$VERSION" "$COMMIT" > "$E/engine.json"

# Same requirement the daemon checks (FigcraftInstaller.signedByTeam) and release.yml's "Conferir motor".
for b in figcraft-server figcraft-cli; do
  codesign --force --options runtime --timestamp --identifier "$b" -s "$ID" "$E/bin/$b"
  codesign --verify --strict --verbose=2 -R="identifier \"$b\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$TEAM\"" "$E/bin/$b"
done

if [ "${COLLIE_SKIP_NOTARIZE:-}" = 1 ]; then echo "warning: not notarized (COLLIE_SKIP_NOTARIZE=1)"
else
  ZIP="$STAGE/bin.zip"
  ditto -c -k --keepParent "$E/bin" "$ZIP"
  # ponytail: same polling loop as release.sh (no --wait: it dies on a network timeout)
  SUB="$(xcrun notarytool submit "$ZIP" "${AUTH[@]}" --output-format json | plutil -extract id raw -o - -)"
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
  rm -f "$ZIP"
fi

mkdir -p build
ASSET="figcraft-$VERSION-arm64.tar.gz"; OUT="build/$ASSET"
rm -f "$OUT" "$OUT.sha256"
# no ._* AppleDouble files, no xattrs (com.apple.provenance, quarantine) in the archive
COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -czf "$OUT" -C "$STAGE" figcraft
(cd build && shasum -a 256 "$ASSET" > "$ASSET.sha256")

# Round trip: what the installer will see (it refuses links and anything outside figcraft/).
X="$STAGE/x"; mkdir "$X"
tar -xzf "$OUT" -C "$X"
stray="$(tar -tzf "$OUT" | grep -v '^figcraft/' || true)"
[ -z "$stray" ] || { echo "error: entries outside figcraft/ in $OUT: $stray" >&2; exit 1; }
bad="$(find "$X" \( -name '._*' -o -type l \) -print)"
[ -z "$bad" ] || { echo "error: AppleDouble or symlink in $OUT: $bad" >&2; exit 1; }
UNPACKED="$(find "$X/figcraft" -type f -exec stat -f %z {} + | awk '{s += $1} END {print s + 0}')"

printf 'sha256=%s\nsize=%s\nunpackedSize=%s\n' "$(cut -d' ' -f1 "$OUT.sha256")" "$(stat -f %z "$OUT")" "$UNPACKED" >&3
echo "ok: $OUT"
