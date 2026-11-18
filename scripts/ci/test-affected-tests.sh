#!/bin/bash
# Check of scripts/ci/affected-tests.sh against the real Package.swift graph. Run: scripts/ci/test-affected-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
A=scripts/ci/affected-tests.sh
fail() { echo "FAIL: $*" >&2; exit 1; }
has() { [[ "|$1|" == *"|$2|"* ]]; }

# docs, non-CI scripts and the CI scripts themselves → nothing to test
[ "$($A --files docs/x.md)" = "" ] || fail "doc: not empty"
[ "$($A --files README.md scripts/bundle.sh scripts/ci/affected-tests.sh)" = "" ] || fail "scripts: not empty"

# a source target → every test target that depends on it, directly or transitively
out="$($A --files Sources/CollieTheme/x.swift)"
has "$out" CollieThemeTests || fail "theme: no CollieThemeTests ($out)"
has "$out" CollieAppTests || fail "theme: no CollieAppTests ($out)"
has "$out" CollieNetworkTests && fail "theme: has CollieNetworkTests ($out)"
[ "$(tr '|' '\n' <<<"$out" | sort -u | paste -sd'|' -)" = "$out" ] || fail "theme: not sorted and unique ($out)"

out="$($A --files Sources/CollieProtocol/x.swift)"
has "$out" CollieDaemonKitTests || fail "protocol: no CollieDaemonKitTests ($out)"

# a test file → its own target only; several files → union, docs ignored
[ "$($A --files Tests/CollieCoreTests/x.swift)" = CollieCoreTests ] || fail "test file: not exactly CollieCoreTests"
[ "$($A --files docs/x.md Tests/CollieThemeTests/x.swift Tests/CollieCoreTests/x.swift)" = "CollieCoreTests|CollieThemeTests" ] || fail "union"

# manifest, lockfile, resources, shared fixtures → everything, even next to other files
[ "$($A --files Package.swift)" = ALL ] || fail "Package.swift: not ALL"
[ "$($A --files Package.resolved)" = ALL ] || fail "Package.resolved: not ALL"
[ "$($A --files Resources/Info.plist)" = ALL ] || fail "Resources: not ALL"
[ "$($A --files Tests/Fixtures/x.json)" = ALL ] || fail "Fixtures: not ALL"
[ "$($A --files docs/x.md Sources/CollieTheme/x.swift Package.swift)" = ALL ] || fail "mixed: not ALL"

# git mode: nothing changed against HEAD itself → empty
[ "$($A HEAD)" = "" ] || fail "git HEAD: not empty"
echo "ok: affected-tests.sh"
