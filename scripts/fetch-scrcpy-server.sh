#!/bin/bash
# Downloads the pinned scrcpy-server (Apache-2.0, see Resources/NOTICE-scrcpy) to vendor/scrcpy-server (git-ignored);
# bundle-app.sh copies it into Collie.app. Fails if the download does not match the pinned SHA-256.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=3.3.1
# Matches PREBUILT_SERVER_SHA256 in upstream install_release.sh at tag v3.3.1.
SHA256=a0f70b20aa4998fbf658c94118cd6c8dab6abbb0647a3bdab344d70bc1ebcbb8
URL="https://github.com/Genymobile/scrcpy/releases/download/v$VERSION/scrcpy-server-v$VERSION"
mkdir -p vendor
tmp="$(mktemp vendor/scrcpy-server.XXXXXX)"
trap 'rm -f "$tmp"' EXIT
curl -fsSL --retry 3 -o "$tmp" "$URL"
got="$(shasum -a 256 "$tmp" | cut -d' ' -f1)"
if [ "$got" != "$SHA256" ]; then
  echo "scrcpy-server v$VERSION: SHA-256 mismatch (got $got, want $SHA256)" >&2; exit 1
fi
chmod 644 "$tmp"; mv "$tmp" vendor/scrcpy-server
echo "ok: vendor/scrcpy-server (v$VERSION)"
