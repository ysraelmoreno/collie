#!/bin/bash
# The CI test run, with a verdict that depends on the code only. Run after `swift build --build-tests`:
#   scripts/ci/run-tests.sh            (SHARDS=3, logs in $OUT, default a temp dir)
#
# Why not a bare `swift test`: its exit code is the test process's, and that process can end early. Run 44660112287
# went green with 237 recorded issues because the process exited 0 mid-run (no "Test run with N tests" line), and
# 44521855224 died on a Fatal error. Running everything in parallel on a 3-core runner also starved the tests (median
# 43 s for tests that take 0.1 s), so timeouts failed at random.
#
# So: the tests listed by `swift test list`, minus scripts/ci/ci-skip.txt, are split by top-level suite into SHARDS
# processes run side by side, each serial (`--no-parallel`). A shard passes only if swift test exits 0, prints no
# failure or Fatal error, and its last line says "Test run with N tests … passed" with N the count it was given.
set -euo pipefail
cd "$(dirname "$0")/../.."
SWIFT="${SWIFT:-swift}"             # the test replaces it
SKIP_FILE="${SKIP_FILE:-scripts/ci/ci-skip.txt}"
SHARDS="${SHARDS:-3}"
OUT="${OUT:-$(mktemp -d)}"
mkdir -p "$OUT"
fail() { echo "run-tests: $*" >&2; exit 1; }

# ci-skip.txt: "<regex over the test id>  # <reason>" per line; a pattern without a reason, or matching no test, fails
patterns=()
while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" == *" # "* ]] || fail "$SKIP_FILE: no reason (\"  # why\") in: $line"
    p="${line%% # *}"; p="${p%"${p##*[![:space:]]}"}"
    [ -n "${line#* # }" ] && [ -n "$p" ] || fail "$SKIP_FILE: empty pattern or reason in: $line"
    # swift-testing matches --skip against more than the listed id: a "$" there skips nothing (the count check would fail)
    [[ "$p" != *'$' ]] || fail "$SKIP_FILE: no trailing \$ (swift-testing would skip nothing): $p"
    patterns+=("$p")
done < "$SKIP_FILE"

"$SWIFT" test list --skip-build > "$OUT/all.txt" || fail "swift test list failed"
grep -q . "$OUT/all.txt" || fail "swift test list listed no test"
cp "$OUT/all.txt" "$OUT/run.txt"
for p in ${patterns[@]+"${patterns[@]}"}; do
    grep -Eq -- "$p" "$OUT/all.txt" || fail "$SKIP_FILE: '$p' matches no test: remove it"
    grep -Ev -- "$p" "$OUT/run.txt" > "$OUT/tmp.txt" || true; mv "$OUT/tmp.txt" "$OUT/run.txt"
done
echo "run-tests: $(wc -l < "$OUT/all.txt" | tr -d ' ') tests, $(wc -l < "$OUT/run.txt" | tr -d ' ') to run, ${#patterns[@]} skip patterns"

# shards: suites (the id up to its first "/") biggest first, each to the shard with the fewest tests so far
cut -d/ -f1 "$OUT/run.txt" | sort | uniq -c | sort -k1,1nr -k2 | awk -v n="$SHARDS" -v out="$OUT" '
    { best = 0; for (i = 1; i < n; i++) if (c[i] < c[best]) best = i
      c[best] += $1; print $2 > (out "/suites-" best ".txt") }
    END { for (i = 0; i < n; i++) print c[i] + 0 > (out "/count-" i ".txt") }'

pids=()
for ((i = 0; i < SHARDS; i++)); do
    [ -s "$OUT/suites-$i.txt" ] || continue
    args=()
    while IFS= read -r s; do args+=(--filter "^${s//./\\.}/"); done < "$OUT/suites-$i.txt"
    for p in ${patterns[@]+"${patterns[@]}"}; do args+=(--skip "$p"); done
    # --ignore-lock: the shards only read the built .build (--skip-build); without it they would wait for each other
    ( start=$SECONDS; set +e
      "$SWIFT" test --skip-build --ignore-lock --disable-sandbox --no-parallel "${args[@]}" > "$OUT/shard-$i.log" 2>&1
      echo "$? $((SECONDS - start))" > "$OUT/rc-$i.txt" ) &
    pids+=($!)
done
wait ${pids[@]+"${pids[@]}"}

bad=0
for ((i = 0; i < SHARDS; i++)); do
    [ -s "$OUT/suites-$i.txt" ] || continue
    log="$OUT/shard-$i.log"; want=$(cat "$OUT/count-$i.txt"); read -r rc secs < "$OUT/rc-$i.txt"
    last=$(grep -E '^(✔|✘) Test run with [0-9]+ tests? ' "$log" | tail -1 || true)
    got=$(sed -E 's/^(✔|✘) Test run with ([0-9]+) .*/\2/' <<< "$last")
    why=()
    [ "$rc" = 0 ] || why+=("exit $rc")
    [ -n "$last" ] || why+=("no 'Test run with N tests' line: the test process ended early")
    [ -z "$last" ] || [ "$got" = "$want" ] || why+=("ran $got tests, expected $want")
    [ -z "$last" ] || [[ "$last" == *" passed after "* ]] || why+=("$last")
    grep -q '^✘ ' "$log" && why+=("$(grep -c '^✘ Test .* recorded an issue' "$log" || true) recorded issues")
    grep -q 'Fatal error' "$log" && why+=("Fatal error")
    if [ ${#why[@]} = 0 ]; then
        echo "run-tests: shard $i ok: $want tests, ${secs}s"
    else
        bad=1
        echo "::group::shard $i FAILED (${secs}s): $(IFS=';'; echo "${why[*]}")"
        grep -E '^✘ |Fatal error' "$log" | head -200 || true
        echo "--- last lines of $log"; tail -20 "$log"
        echo "::endgroup::"
        echo "run-tests: shard $i FAILED: $(IFS=';'; echo "${why[*]}")" >&2
    fi
done
[ "$bad" = 0 ] || { echo "run-tests: full logs in $OUT" >&2; exit 1; }
echo "run-tests: all shards passed"
