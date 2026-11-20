#!/bin/bash
# Builds the Vizinho plug-in folder: Examples/plugins/vizinho + the release helper at bin/vizinho.
# Usage: scripts/build-vizinho-plugin.sh [<dest>]   (default .build/plugins/vizinho). The binary is never committed.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="${1:-.build/plugins/vizinho}"

swift build -c release --product collie-vizinho
BIN="$(swift build -c release --show-bin-path)/collie-vizinho"

rm -rf "$DEST" && mkdir -p "$DEST/bin"
cp -R Examples/plugins/vizinho/. "$DEST/"
cp "$BIN" "$DEST/bin/vizinho" && chmod 755 "$DEST/bin/vizinho"
echo "ok: $DEST"
