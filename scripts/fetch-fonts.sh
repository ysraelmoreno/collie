#!/bin/bash
# Downloads Space Grotesk + DM Mono (SIL OFL 1.1, see Resources/NOTICE-fonts) from a pinned google/fonts commit to
# vendor/fonts (git-ignored); bundle-app.sh copies them into Collie.app. Fails if any file does not match its pinned SHA-256.
set -euo pipefail
cd "$(dirname "$0")/.."
COMMIT=45e3d5269e4a17d823f6d84470bc084dc5ae46f6   # google/fonts main on 2026-10-21
BASE="https://raw.githubusercontent.com/google/fonts/$COMMIT/ofl"
# "remote path|local name|sha256"; [wght] is URL-encoded in the remote path
FILES=(
  "spacegrotesk/SpaceGrotesk%5Bwght%5D.ttf|SpaceGrotesk[wght].ttf|acad6de1fc93436f5c0f1f4137751ef04f1aea3063e7036535970ffcfbd79f72"
  "spacegrotesk/OFL.txt|OFL-SpaceGrotesk.txt|564ce565c371c5e5bbf286006565a7c9aa55a9f56e7ca58d56e05d649dd61a72"
  "dmmono/DMMono-Regular.ttf|DMMono-Regular.ttf|55b4c98f123daebb3ed27947ba47b2af00554fc6284d639a540bcef5e6258ad2"
  "dmmono/DMMono-Medium.ttf|DMMono-Medium.ttf|fd327daf461db87b44a87def475d251bf03b997f7c07d9680592d75dbbfaad0b"
)
mkdir -p vendor/fonts
tmp="$(mktemp vendor/fonts.XXXXXX)"
trap 'rm -f "$tmp"' EXIT
for entry in "${FILES[@]}"; do
  IFS='|' read -r remote name sha <<<"$entry"
  curl -fsSL --retry 3 -o "$tmp" "$BASE/$remote"
  got="$(shasum -a 256 "$tmp" | cut -d' ' -f1)"
  if [ "$got" != "$sha" ]; then
    echo "$name: SHA-256 mismatch (got $got, want $sha)" >&2; exit 1
  fi
  chmod 644 "$tmp"; mv "$tmp" "vendor/fonts/$name"
  tmp="$(mktemp vendor/fonts.XXXXXX)"
done
echo "ok: vendor/fonts (google/fonts@${COMMIT:0:7})"
