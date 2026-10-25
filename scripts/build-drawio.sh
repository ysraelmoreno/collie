#!/bin/bash
# Vendors the pinned, patched draw.io embed webapp into vendor/drawio/{web,LICENSE}. Idempotent.
# Only what embed mode (index.html?embed=1&proto=json&offline=1) loads: no Confluence/viewer bundles, dev sources,
# Java servlet, service worker, templates or math. Measured size of vendor/drawio/web: 34 MB (34764 KiB, v32.6.1).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

DRAWIO_TAG=v32.6.1
DRAWIO_COMMIT=84487b4891cbc0f32d7e30f34cf878c87cb1f414

SRC=vendor/drawio-src
OUT=vendor/drawio

if [ ! -d "$SRC/.git" ]; then git clone --depth 1 --branch "$DRAWIO_TAG" https://github.com/jgraph/drawio "$SRC"; fi
[ "$(git -C "$SRC" rev-parse HEAD)" = "$DRAWIO_COMMIT" ] || { echo "error: $SRC is not $DRAWIO_TAG ($DRAWIO_COMMIT)" >&2; exit 1; }

# Patches: re-applied on a clean tree only when the set changes.
STAMP="$SRC/.collie-patches"
PATCHES_SUM="$(cat patches/drawio/*.patch | shasum -a 256 | cut -d' ' -f1)"
if [ "$(cat "$STAMP" 2>/dev/null)" != "$PATCHES_SUM" ]; then
  git -C "$SRC" checkout -q -- . && git -C "$SRC" clean -fdq
  for p in patches/drawio/*.patch; do git -C "$SRC" apply --check "$ROOT/$p"; git -C "$SRC" apply "$ROOT/$p"; done
  echo "$PATCHES_SUM" >"$STAMP"
fi

rm -rf "$OUT/web" && mkdir -p "$OUT/web"
# ponytail: Azure/MS cloud icon sets (6.4 MB) left out to stay under 40 MB; only "Mais formas" > Azure needs them.
(cd "$SRC/src/main/webapp" && rsync -aR --exclude img/lib/azure2 --exclude img/lib/mscae \
  index.html favicon.ico \
  js/bootstrap.js js/main.js js/PreConfig.js js/PostConfig.js \
  js/app.min.js js/extensions.min.js js/stencils.min.js js/shapes-14-6-5.min.js \
  resources/dia.txt resources/dia_pt-br.txt \
  styles images img mxgraph/css mxgraph/images shapes stencils \
  "$ROOT/$OUT/web/")
cp "$SRC/LICENSE" "$OUT/LICENSE"
echo "ok: $OUT ($(du -sh "$OUT" | cut -f1))"
