#!/bin/bash
# Builds the pinned, patched figcraft v0.7.0 into vendor/figcraft/{bin,web,licenses}. Idempotent.
# No public collab server (FIGCRAFT_DEFAULT_SERVER empty), craft-fonts embedded (Inter in the web build).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

FIGCRAFT_TAG=v0.7.0
FIGCRAFT_COMMIT=47438dd4a2e8b49a7e6bb3dfd480262dadc37f12
# Same ref figcraft's own release workflow embeds (.github/workflows/release.yml craft-fonts-ref).
CRAFT_FONTS_COMMIT=43913056ce82a3fdad0ef69f6b88d1dc922a8104
TRUNK_VERSION=0.22.0
WASM_BINDGEN_VERSION=0.2.129 # must equal wasm-bindgen in figcraft's Cargo.lock (checked below)
BINARYEN_VERSION=version_131 # trunk 0.22.0 default
BINARYEN_SHA256=e441b48dc22163d209b4f05e44dc7210909b01237642b6c9ae48fd710a3ef83e

SRC=vendor/figcraft-src
FONTS=vendor/craft-fonts
TOOLS=vendor/figcraft-tools
OUT=vendor/figcraft

# rustup is keg-only: only this script sees it, Homebrew's rust stays the user's default.
export PATH="/opt/homebrew/opt/rustup/bin:$ROOT/$TOOLS/bin:$PATH"
if ! command -v rustup >/dev/null; then
  echo "error: needs rustup: brew install rustup && rustup-init -y --no-modify-path" >&2
  exit 1
fi
# Pinned compiler: a toolchain named after it, or `stable` while stable is that release (never auto-installed here).
RUST_VERSION=1.99.1
export RUSTUP_AUTO_INSTALL=0; unset RUSTUP_TOOLCHAIN
for tc in "$RUST_VERSION" stable; do
  if RUSTUP_TOOLCHAIN="$tc" rustc --version 2>/dev/null | grep -q "^rustc $RUST_VERSION "; then export RUSTUP_TOOLCHAIN="$tc"; break; fi
done
if [ -z "${RUSTUP_TOOLCHAIN:-}" ]; then
  echo "error: needs Rust $RUST_VERSION (stable is $(RUSTUP_TOOLCHAIN=stable rustc --version 2>/dev/null || echo "not installed")):" >&2
  echo "  rustup toolchain install $RUST_VERSION && rustup target add --toolchain $RUST_VERSION wasm32-unknown-unknown" >&2
  exit 1
fi
if ! rustup target list --installed | grep -qx wasm32-unknown-unknown; then
  echo "error: Rust $RUST_VERSION ($RUSTUP_TOOLCHAIN) needs the wasm32-unknown-unknown target:" >&2
  echo "  rustup target add --toolchain $RUSTUP_TOOLCHAIN wasm32-unknown-unknown" >&2
  exit 1
fi

if [ ! -d "$SRC/.git" ]; then git clone --depth 1 --branch "$FIGCRAFT_TAG" https://github.com/storytold/figcraft "$SRC"; fi
[ "$(git -C "$SRC" rev-parse HEAD)" = "$FIGCRAFT_COMMIT" ] || { echo "error: $SRC is not $FIGCRAFT_TAG ($FIGCRAFT_COMMIT)" >&2; exit 1; }

if [ ! -d "$FONTS/.git" ]; then
  mkdir -p "$FONTS"; git -C "$FONTS" init -q
  git -C "$FONTS" fetch -q --depth 1 https://github.com/storytold/craft-fonts "$CRAFT_FONTS_COMMIT"
  git -C "$FONTS" checkout -q FETCH_HEAD
fi
[ "$(git -C "$FONTS" rev-parse HEAD)" = "$CRAFT_FONTS_COMMIT" ] || { echo "error: $FONTS is not $CRAFT_FONTS_COMMIT" >&2; exit 1; }

# Patches: re-applied on a clean tree only when the set changes (untouched files keep cargo's cache).
STAMP="$SRC/.collie-patches"  # ponytail: renamed with the figcraft patches (plan 4R Task 4)
PATCHES_SUM="$(cat patches/figcraft/*.patch | shasum -a 256 | cut -d' ' -f1)"
if [ "$(cat "$STAMP" 2>/dev/null)" != "$PATCHES_SUM" ]; then
  git -C "$SRC" checkout -q -- . && git -C "$SRC" clean -fdq -e target -e dist
  for p in patches/figcraft/*.patch; do git -C "$SRC" apply --check "$ROOT/$p"; git -C "$SRC" apply "$ROOT/$p"; done
  echo "$PATCHES_SUM" >"$STAMP"
fi

grep -A1 '^name = "wasm-bindgen"$' "$SRC/Cargo.lock" | grep -qx "version = \"$WASM_BINDGEN_VERSION\"" \
  || { echo "error: wasm-bindgen in $SRC/Cargo.lock is not $WASM_BINDGEN_VERSION" >&2; exit 1; }
trunk --version 2>/dev/null | grep -q " $TRUNK_VERSION" || cargo install --locked --root "$TOOLS" --version "$TRUNK_VERSION" trunk
wasm-bindgen --version 2>/dev/null | grep -q " $WASM_BINDGEN_VERSION" || cargo install --locked --root "$TOOLS" --version "$WASM_BINDGEN_VERSION" wasm-bindgen-cli
# wasm-opt (binaryen) here too, else trunk downloads it into the user's cache.
if ! wasm-opt --version 2>/dev/null | grep -q "${BINARYEN_VERSION#version_}"; then
  tgz="$TOOLS/binaryen.tar.gz"
  curl -fsSL -o "$tgz" "https://github.com/WebAssembly/binaryen/releases/download/$BINARYEN_VERSION/binaryen-$BINARYEN_VERSION-arm64-macos.tar.gz"
  echo "$BINARYEN_SHA256  $tgz" | shasum -a 256 -c -
  tar -xzf "$tgz" -C "$TOOLS" && rm "$tgz"
  mkdir -p "$TOOLS/bin" "$TOOLS/lib"
  cp "$TOOLS/binaryen-$BINARYEN_VERSION/bin/wasm-opt" "$TOOLS/bin/"
  cp "$TOOLS/binaryen-$BINARYEN_VERSION/lib/"* "$TOOLS/lib/"
  rm -rf "$TOOLS/binaryen-$BINARYEN_VERSION"
fi

export FIGCRAFT_DEFAULT_SERVER= # empty: online sharing stays off (crates/engine/src/live.rs DEFAULT_SERVER)
export CRAFT_FONTS_DIR="$ROOT/$FONTS" CRAFT_FONTS_REQUIRED=1
export FIGCRAFT_BUILD_SHA="$FIGCRAFT_COMMIT"
(cd "$SRC" && cargo build --release --locked -p figcraft-server -p figcraft-cli)
(cd "$SRC/apps/figcraft-web" && trunk build --release --offline --public-url ./)

mkdir -p "$OUT/bin" "$OUT/web" "$OUT/licenses"
cp "$SRC/target/release/figcraft-server" "$SRC/target/release/figcraft-cli" "$OUT/bin/"
rsync -a --delete --exclude .trunk-lock "$SRC/dist/web/" "$OUT/web/"
cp "$SRC/LICENSE-APACHE" "$SRC/LICENSE-MIT" "$SRC/NOTICE" "$OUT/licenses/"
# Embedded fonts are OFL-1.1: ship each family's licence (same naming as figcraft's packaging/env.sh).
for lic in "$FONTS"/fonts/*/OFL.txt; do cp "$lic" "$OUT/licenses/OFL-$(basename "$(dirname "$lic")").txt"; done
echo "ok: $OUT ($(du -sh "$OUT" | cut -f1))"
