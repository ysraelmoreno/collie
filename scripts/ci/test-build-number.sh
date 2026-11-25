#!/bin/bash
# Offline check of scripts/ci/build-number.sh. Run: scripts/ci/test-build-number.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
B=scripts/ci/build-number.sh
fail() { echo "FAIL: $*" >&2; exit 1; }
eq() { [ "$($B "$1" 2>/dev/null)" = "$2" ] || fail "$1 -> $($B "$1" 2>&1) (want $2)"; }
refused() { if $B "$1" >/dev/null 2>&1; then fail "accepted \"$1\""; fi; }
eq v0.2.2 2002; eq 0.2.2 2002; eq v1.0.0 1000000; eq v0.2.999 2999; eq v0.3.0 3000; eq v0.2.02 2002
[ "$($B v0.2.999)" -lt "$($B v0.3.0)" ] || fail "order across minor"
[ "$($B v0.9.9)" -lt "$($B v1.0.0)" ] || fail "order across major"
for bad in v1.2 v1.2.3-rc1 "" vA.B.C v1.2.3.4 v0.1000.0 v0.0.1000; do refused "$bad"; done
echo "ok: build-number"
