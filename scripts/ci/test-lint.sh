#!/bin/bash
# Offline check of scripts/ci/lint.sh on a fabricated tree (LINT_ROOT). Run: scripts/ci/test-lint.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
L="$PWD/scripts/ci/lint.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export LINT_ROOT="$T"
mkdir -p "$T/Sources/A" "$T/scripts/ci"
printf 'func a() async {\n  try? await Task.sleep(for: .seconds(1))\n  let x = y as! Int\n}\n' > "$T/Sources/A/a.swift"
printf 'final class B: @unchecked Sendable {}\n' > "$T/Sources/A/b.swift"
run() { set +e; "$L" "$@" >"$T/out" 2>"$T/err"; rc=$?; set -e; }

# no baseline yet: everything is new -> fails; hand-written baseline equal to the tree -> passes
run; [ "$rc" = 1 ] || fail "no baseline should fail (rc=$rc)"
printf 'force Sources/A/a.swift 1\nsleep Sources/A/a.swift 1\nunsafe-concurrency Sources/A/b.swift 1\n' > "$T/scripts/ci/lint-baseline.txt"
run; [ "$rc" = 0 ] || fail "exact baseline should pass: $(cat "$T/err")"

# a new sleep in an existing file
printf 'func c() async { try? await Task.sleep(for: .seconds(2)) }\n' >> "$T/Sources/A/a.swift"
run; [ "$rc" = 1 ] || fail "new sleep should fail"
grep -q "regra 'sleep' em Sources/A/a.swift" "$T/err" || fail "message names rule and file"
grep -q "Sources/A/a.swift:" "$T/err" || fail "message names file:line"
grep -q "espere o evento" "$T/err" || fail "message names root cause"

# a new file outside the baseline
sed -i '' '$d' "$T/Sources/A/a.swift"
printf 'func d() { usleep(5) }\n' > "$T/Sources/A/new.swift"
run; [ "$rc" = 1 ] || fail "file outside baseline should fail"
grep -q "Sources/A/new.swift" "$T/err" || fail "names the new file"
# --update-baseline refuses to add
cp "$T/scripts/ci/lint-baseline.txt" "$T/before"
run --update-baseline; [ "$rc" = 1 ] || fail "update must refuse to add"
cmp -s "$T/before" "$T/scripts/ci/lint-baseline.txt" || fail "refused update wrote the baseline"
rm "$T/Sources/A/new.swift"

# below the baseline fails (ratchet), update lowers it, then passes
printf 'final class B {}\n' > "$T/Sources/A/b.swift"
run; [ "$rc" = 1 ] || fail "below baseline should fail"
grep -q -- "--update-baseline" "$T/err" || fail "tells to run --update-baseline"
run --update-baseline; [ "$rc" = 0 ] || fail "update should lower: $(cat "$T/err")"
! grep -q unsafe-concurrency "$T/scripts/ci/lint-baseline.txt" || fail "line not removed"
run; [ "$rc" = 0 ] || fail "after update should pass"

# feature-map: a panel not named in docs/feature-map.md fails (no baseline for it); naming it passes
mkdir -p "$T/Sources/ColliePlugins" "$T/docs"
printf 'struct FooPanel {}\n' > "$T/Sources/ColliePlugins/FooPanel.swift"
printf 'struct BarPanel {}\n' > "$T/Sources/ColliePlugins/BarPanel.swift"
mkdir -p "$T/Sources/CollieApp"
printf 'panels: ["BarPanel", "FooPanel"]\n' > "$T/Sources/CollieApp/FeatureTour.swift"   # the tour names both: only the feature map is under test
printf '# Mapa\n\n### Bar (`BarPanel`)\n' > "$T/docs/feature-map.md"
run; [ "$rc" = 1 ] || fail "panel missing from the feature map should fail"
grep -q "regra 'feature-map': Sources/ColliePlugins/FooPanel.swift" "$T/err" || fail "names the missing panel"
grep -q "docs/feature-map.md" "$T/err" || fail "says where to add it"
! grep -q "BarPanel" "$T/err" || fail "a named panel must not be reported"
run --update-baseline; run; [ "$rc" = 1 ] || fail "feature-map has no baseline"
rm "$T/docs/feature-map.md"
run; [ "$rc" = 1 ] || fail "no feature map at all should fail"
printf '### Bar (`BarPanel`)\n### Foo (`FooPanel`)\n' > "$T/docs/feature-map.md"
run; [ "$rc" = 0 ] || fail "all panels named should pass: $(cat "$T/err")"

# feature-tour: a panel not named in Sources/CollieApp/FeatureTour.swift fails (no baseline either); naming it passes
printf 'panels: ["BarPanel"]\n' > "$T/Sources/CollieApp/FeatureTour.swift"
run; [ "$rc" = 1 ] || fail "panel missing from the tour should fail"
grep -q "regra 'feature-tour': Sources/ColliePlugins/FooPanel.swift" "$T/err" || fail "names the panel the tour lacks"
grep -q "Sources/CollieApp/FeatureTour.swift" "$T/err" || fail "says where to add it"
! grep -q "BarPanel" "$T/err" || fail "a panel the tour names must not be reported"
! grep -q "regra 'feature-map'" "$T/err" || fail "the feature map is complete: only the tour rule fires"
run --update-baseline; run; [ "$rc" = 1 ] || fail "feature-tour has no baseline"
rm "$T/Sources/CollieApp/FeatureTour.swift"
run; [ "$rc" = 1 ] || fail "no tour table at all should fail"
grep -q "regra 'feature-tour': Sources/ColliePlugins/BarPanel.swift" "$T/err" || fail "names every panel when the table is missing"
printf 'panels: ["FooPanel", "BarPanel"]\n' > "$T/Sources/CollieApp/FeatureTour.swift"
run; [ "$rc" = 0 ] || fail "every panel named in the tour should pass: $(cat "$T/err")"
echo "test-lint: ok"
