#!/bin/bash
# CFBundleVersion from a release tag: MAJOR*1000000 + MINOR*1000 + PATCH (v0.2.2 -> 2002). Sparkle compares this number,
# so it must only ever grow with the tag. Usage: scripts/ci/build-number.sh <vX.Y.Z|X.Y.Z>
set -euo pipefail
T="${1:-}"
[[ "$T" =~ ^v?([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || { echo "build-number: \"$T\" is not vX.Y.Z" >&2; exit 1; }
MA=$((10#${BASH_REMATCH[1]})) MI=$((10#${BASH_REMATCH[2]})) PA=$((10#${BASH_REMATCH[3]}))
(( MI < 1000 && PA < 1000 )) || { echo "build-number: \"$T\": minor and patch must be below 1000" >&2; exit 1; }
echo $((MA * 1000000 + MI * 1000 + PA))
