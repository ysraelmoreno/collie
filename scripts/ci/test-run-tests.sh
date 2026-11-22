#!/bin/bash
# Offline check of scripts/ci/run-tests.sh with a fake `swift`. Run: scripts/ci/test-run-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
R="$PWD/scripts/ci/run-tests.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# the fake: `test list` prints $T/list; a run appends its args to $T/args and prints $T/out-<first suite filtered>
cat > "$T/swift" <<'EOF'
#!/bin/bash
[ "$2" = list ] && { cat "$FAKE/list"; exit 0; }
echo "$*" >> "$FAKE/args"
f=$(sed -E 's/.*--filter \^([^ /]*)\/.*/\1/; s/\\//g' <<< "$*")
cat "$FAKE/out-$f"
ev=$(sed -nE 's/.*--event-stream-output-path ([^ ]*).*/\1/p' <<< "$*")
[ -n "$ev" ] && [ -e "$FAKE/events-$f" ] && cp "$FAKE/events-$f" "$ev"
# a hang: leaves a child in its group and an adb in a session of its own (as adb start-server does), then never ends
if [ -e "$FAKE/hang-$f" ]; then
    sleep 300 & echo $! > "$FAKE/child-pid"
    perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' "$FAKE/adb" 300 & echo $! > "$FAKE/adb-pid"
    while :; do sleep 1; done
fi
exit "$(cat "$FAKE/rc-$f" 2>/dev/null || echo 0)"
EOF
chmod +x "$T/swift"; cp /bin/sleep "$T/adb"
export SWIFT="$T/swift" FAKE="$T" SKIP_FILE="$T/skip" SHARDS=2
printf 'A.S1/a()\nA.S1/b()\nA.S1/c()\nA.S2/d()\nA.S2/e()\n' > "$T/list"
printf '# comment\n\n^A\\.S2/e\\(\\)  # needs a GPU\n' > "$T/skip"
pass() { printf '◇ Test run started.\n✔ Test run with %s tests in 1 suite passed after 1.0 seconds.\n' "$1"; }
run() { rm -f "$T/args"; set +e; OUT="$T/o" "$R" >"$T/stdout" 2>"$T/err"; rc=$?; set -e; rm -rf "$T/o"; }
ok() { pass 3 > "$T/out-A.S1"; pass 1 > "$T/out-A.S2"; rm -f "$T"/rc-* "$T"/hang-*; }
alive() { [ -s "$T/$1" ] && kill -0 "$(cat "$T/$1")" 2>/dev/null; }

ok; run; [ "$rc" = 0 ] || fail "all pass should pass: $(cat "$T/err")"
grep -q "shard 0 ok: 3 testes, [0-9]*s" "$T/stdout" && grep -q "shard 1 ok: 1 testes" "$T/stdout" || fail "summary per shard: $(cat "$T/stdout")"
grep -q "all shards passed" "$T/stdout" || fail "says all passed"

# a shard that hangs: fails within the timeout, names the last test started, and leaves no process behind
ok; printf '◇ Test run started.\n◇ Suite S1 started.\n◇ Test a() started.\n✔ Test a() passed after 0.1 seconds.\n◇ Test b() started.\n' > "$T/out-A.S1"
touch "$T/hang-A.S1"; rm -f "$T/child-pid" "$T/adb-pid"
t0=$SECONDS; CI_SHARD_TIMEOUT=2 run; took=$((SECONDS - t0))
[ "$rc" = 1 ] || fail "a hung shard must fail"
[ "$took" -le 5 ] || fail "timeout 2s took ${took}s"
grep -q "shard 0 FALHOU: 3 testes, [0-9]*s: timeout after 2s" "$T/err" || fail "says timeout: $(cat "$T/err")"
grep -q "last started: ◇ Test b() started" "$T/err" || fail "names the last test started: $(cat "$T/err")"
grep -q "shard 1 ok" "$T/stdout" || fail "the other shard still passes"
grep -q "last 40 lines" "$T/stdout" || fail "prints the log tail"
sleep 0.5; ! alive child-pid || fail "child of the hung shard still alive"
! alive adb-pid || fail "orphan adb still alive"
grep -q -- '--no-parallel' "$T/args" || fail "shards run serially"
grep -q -- '--event-stream-output-path [^ ]*/shard-0.jsonl' "$T/args" || fail "each shard writes an event stream"

# the console log lost its last block (buffered, then KILL): the test named on a timeout comes from the event stream
printf '{"kind":"testStarted","payload":{"testID":"A.S1\\/a()\\/x.swift:1:1"}}\n{"kind":"testStarted","payload":{"testID":"A.S1\\/c()\\/x.swift:9:1"}}\n' > "$T/events-A.S1"
CI_SHARD_TIMEOUT=2 run; rm -f "$T/events-A.S1" "$T/hang-A.S1"
[ "$rc" = 1 ] || fail "a hung shard must fail"
grep -qF "last started: A.S1/c()/x.swift:9:1 (event stream)" "$T/err" || fail "names the test from the event stream: $(cat "$T/err")"
grep -qF -- '--filter ^A\.S1/' "$T/args" && grep -qF -- '--filter ^A\.S2/' "$T/args" || fail "suites filtered anchored: $(cat "$T/args")"
grep -qF -- '--skip ^A\.S2/e\(\)' "$T/args" || fail "skip pattern passed on"
[ "$(wc -l < "$T/args")" -eq 2 ] || fail "one process per shard"

# the false green of run 44660112287: exit 0, issues recorded, no final line
ok; printf '◇ Test a() started.\n✘ Test a() recorded an issue at x.swift:1:1: Expectation failed\n◇ Test b() started.\n' > "$T/out-A.S1"
run; [ "$rc" = 1 ] || fail "exit 0 without the final line must fail"
grep -q "shard .* FALHOU.*the test process ended early" "$T/err" || fail "says it ended early: $(cat "$T/err")"
grep -q "1 recorded issues" "$T/err" || fail "counts issues"
ok; printf '◇ Test run started.\n◇ Test a() started.\n✔ Test a() passed after 0.1 seconds.\n' > "$T/out-A.S1"
run; [ "$rc" = 1 ] || fail "exit 0 with nothing failed but no final line must fail"

# a summary saying passed but an issue in the log, or a Fatal error
ok; { printf '✘ Test a() recorded an issue at x.swift:1:1: boom\n'; pass 3; } > "$T/out-A.S1"
run; [ "$rc" = 1 ] || fail "recorded issue must fail even with a passed summary"
ok; { printf 'Fatal error: Attempted to read an unowned reference\n'; pass 3; } > "$T/out-A.S1"
run; [ "$rc" = 1 ] || fail "Fatal error must fail"; grep -q "Fatal error" "$T/err" || fail "names Fatal error"

# fewer tests than given (the run stopped part way), a failed summary, a nonzero exit
ok; pass 2 > "$T/out-A.S1"
run; [ "$rc" = 1 ] || fail "wrong count must fail"; grep -q "ran 2 tests, expected 3" "$T/err" || fail "names the counts"
ok; printf '✘ Test run with 3 tests in 1 suite failed after 1.0 seconds with 1 issue.\n' > "$T/out-A.S1"
run; [ "$rc" = 1 ] || fail "failed summary must fail"
ok; echo 1 > "$T/rc-A.S2"
run; [ "$rc" = 1 ] || fail "nonzero exit must fail"; grep -q "shard 1 FALHOU: 1 testes, [0-9]*s: exit 1" "$T/err" || fail "names the exit"
ok; { printf '✘ Test d() recorded an issue at x.swift:1:1: boom text\n'; } > "$T/out-A.S2"; echo 1 > "$T/rc-A.S2"
run; [ "$rc" = 1 ] || fail "a failing shard must fail"; grep -q "boom text" "$T/stdout" || fail "prints the log tail"

# ci-skip.txt: a pattern without a reason, or one matching nothing, fails before running anything
ok; printf '^A\\.S2/e\\(\\)\n' > "$T/skip"
run; [ "$rc" = 1 ] || fail "pattern without reason must fail"; grep -q "no reason" "$T/err" || fail "says no reason"
[ ! -e "$T/args" ] || fail "nothing runs on a bad skip file"
printf '^A\\.S2/e\\(\\)$  # anchored\n' > "$T/skip"
run; [ "$rc" = 1 ] || fail "trailing \$ must fail"; grep -q 'no trailing' "$T/err" || fail "says no trailing \$"
printf '^A\\.S9/x\\(\\)  # gone\n' > "$T/skip"
run; [ "$rc" = 1 ] || fail "stale pattern must fail"; grep -q "matches no test" "$T/err" || fail "says stale"

# a @Test outside any suite (id "A.f()", no "/") runs: filtered by its escaped id, not "^A\.f()/" (matches nothing)
printf '' > "$T/skip"; printf 'A.S1/a()\nA.S1/b()\nA.S1/c()\nA.f()\n' > "$T/list"; ok; pass 4 > "$T/out-A.S1"
SHARDS=1 run; [ "$rc" = 0 ] || fail "a free test function must run: $(cat "$T/err")"
grep -qF -- '--filter ^A\.f\(\)' "$T/args" || fail "free function filtered by its escaped id: $(cat "$T/args")"
! grep -qF -- 'A\.f\(\)/' "$T/args" || fail "no trailing / on a free function: $(cat "$T/args")"

# an empty list (the build or discovery broke) fails
printf '' > "$T/skip"; : > "$T/list"
run; [ "$rc" = 1 ] || fail "no tests must fail"
echo "test-run-tests: ok"
