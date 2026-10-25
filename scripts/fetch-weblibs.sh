#!/bin/bash
# Vendors the pinned offline web libraries into vendor/weblibs/<name>@<version>/{<file>,LICENSE*} + manifest.json,
# served to local pages as collie-lib://lib/<name>@<version>/<file>. Idempotent. The only network use: the npm
# registry tarballs below, each checked against its pinned SHA-256; no npm, no install scripts — only the listed
# UMD file and the licence are extracted. A mismatch or a failed download leaves an existing vendor/weblibs untouched.
# Pinned: react 18.3.1, react-dom 18.3.1, htm 3.1.1, chart.js 4.4.9, lucide 0.469.0. Measured size of vendor/weblibs: 736 KiB.
# --print-sums: download and print each tarball's SHA-256 without checking (only to fill the pins once).
set -euo pipefail
cd "$(dirname "$0")/.."

# name version path-in-tarball sha256 licence global
LIBS="
react     18.3.1  umd/react.production.min.js      8d9bed01a672e7eaf387942d781ad47c6a43089a30a0306060f9fd5ac7870347 MIT React
react-dom 18.3.1  umd/react-dom.production.min.js  031d4427a99f2f3f6cac18bbbf308594a67e4f47d10f4896fdec446505b040e0 MIT ReactDOM
htm       3.1.1   dist/htm.umd.js                  2425b9bee11409177bcabc7f32e319926fc6690c1701c0b257c88bdff2d5ba90 Apache-2.0 htm
chart.js  4.4.9   dist/chart.umd.js                2af62960ba6c9a8b459be41e7911a030eb68f4375ea6a3e0f513ef5dbb0f0aca MIT Chart
lucide    0.469.0 dist/umd/lucide.min.js           58d72a5b4e8cf4f5d12ef67e7fcf0f87390706cc5b75b82a4b7e2938481ee63f ISC lucide
"
PRINT=0; [ "${1:-}" = "--print-sums" ] && PRINT=1

OUT=vendor/weblibs
mkdir -p vendor
TMP="$(mktemp -d vendor/.weblibs.XXXXXX)"   # same volume as $OUT: the final mv is a rename
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/tgz" "$TMP/out"

manifest="["; sep=""
while read -r name version path sum licence global; do
  [ -n "$name" ] || continue
  tgz="$TMP/tgz/$name-$version.tgz"
  curl -fsSL --proto '=https' --proto-redir '=https' -o "$tgz" "https://registry.npmjs.org/$name/-/${name##*/}-$version.tgz"
  got="$(shasum -a 256 "$tgz" | cut -d' ' -f1)"
  if [ "$PRINT" = 1 ]; then echo "$name $version $got"; continue; fi
  [ "$got" = "$sum" ] || { echo "error: sha256 mismatch: $name ($got)" >&2; exit 1; }
  dir="$TMP/out/$name@$version"; x="$TMP/x-$name"
  mkdir -p "$dir" "$x"
  # bsdtar: arguments are patterns; only these members are written
  tar -xzf "$tgz" -C "$x" "package/$path" 'package/LICENSE*'
  # regular files only: a member that is a link is refused, never followed
  for f in "$x/package/$path" "$x"/package/LICENSE*; do
    [ -f "$f" ] && [ ! -L "$f" ] || { echo "error: not a regular file in $name: ${f#"$x/"}" >&2; exit 1; }
    cp -P "$f" "$dir/"
  done
  manifest+="$sep"$'\n'"$(printf '  {"name":"%s","version":"%s","files":["%s"],"licence":"%s","global":"%s"}' \
    "$name" "$version" "$(basename "$path")" "$licence" "$global")"; sep=","
done <<<"$LIBS"
[ "$PRINT" = 1 ] && exit 0
printf '%s\n]\n' "$manifest" >"$TMP/out/manifest.json"

rm -rf "$OUT.old"
[ -e "$OUT" ] && mv "$OUT" "$OUT.old"
mv "$TMP/out" "$OUT" && rm -rf "$OUT.old"
echo "ok: $OUT ($(du -sh "$OUT" | cut -f1))"
