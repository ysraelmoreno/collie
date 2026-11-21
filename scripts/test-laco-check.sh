#!/bin/bash
# Offline check of scripts/laco-check.sh with a fake `swift` on PATH and a temporary Tests/. Run: scripts/test-laco-check.sh
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="$PWD/scripts/laco-check.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# the fake applies the real rule: each --filter is a regex over the test ids (Module.Suite/test()) of the suites declared in
# Tests/; it records what each filter matched, and a filter matching nothing is recorded (real swift would run 0 tests, green)
mkdir -p "$T/bin" "$T/fake"
cat > "$T/bin/swift" <<'EOF'
#!/bin/bash
ids() { grep -rhoE --include='*.swift' '(struct|class|actor|enum)[[:space:]]+[A-Za-z0-9_]+' Tests | awk '{print "CollieDaemonKitTests."$2"/t()"}'; }
if [ "$1 $2" = "test list" ]; then [ -n "${FAKE_NOLIST:-}" ] && { echo "error: no build" >&2; exit 1; }; ids; exit 0; fi
[ "$1" = test ] || { echo "fake swift: unexpected $*" >&2; exit 64; }
echo "$*" >> "$FAKE/args"
all=$(ids); ran=(); rc=0
while [ $# -gt 0 ]; do
  if [ "$1" = --filter ]; then
    m=$(grep -E -- "$2" <<< "$all" | sed -E 's/^[^.]*\.([^/]*)\/.*/\1/' | sort -u | tr '\n' ' ')
    echo "$2 -> ${m% }" >> "$FAKE/matches"
    [ -n "$m" ] || echo "$2" >> "$FAKE/unmatched"
    ran+=($m); shift
  fi
  shift
done
echo '◇ Test run started.'
for s in $(printf '%s\n' ${ran[@]+"${ran[@]}"} | sort -u); do
  echo "$s" >> "$FAKE/ran"
  if [ -e "$FAKE/flaky-$s" ]; then rm "$FAKE/flaky-$s"; echo "✘ Test $s/t() recorded an issue at x.swift:1:1: boom"; echo "✘ Suite $s failed after 0.1 seconds with 1 issue."; rc=1
  elif [ -e "$FAKE/broken-$s" ]; then echo "✘ Test $s/t() recorded an issue at x.swift:1:1: boom"; echo "✘ Suite $s failed after 0.1 seconds with 1 issue."; rc=1
  else echo "✔ Suite $s passed after 0.1 seconds."; fi
done
[ "$rc" = 0 ] && echo "✔ Test run with ${#ran[@]} tests passed after 1.0 seconds." || echo "✘ Test run with ${#ran[@]} tests failed after 1.0 seconds with 1 issue."
exit "$rc"
EOF
chmod +x "$T/bin/swift"
export PATH="$T/bin:$PATH" FAKE="$T/fake"

# a repo copy: the script under test, and one declaration per suite of its list (+ the need files of the cases used)
R="$T/repo"; mkdir -p "$R/scripts" "$R/Tests/CollieDaemonKitTests"
SUITES=$(sed -n '/^suites=(/,/)/p' "$SRC" | tr -d '()' | sed 's/suites=//' | tr -s ' \n' '\n' | grep .)
SMOKE="WorkLoopTests AttemptMachineTests WorkStoreTests LoopJournalTests CommandsTests"
for s in $SUITES; do printf '@Suite struct %s {}\n' "$s" > "$R/Tests/CollieDaemonKitTests/$s.swift"; done
N=$(wc -w <<< "$SUITES" | tr -d ' ')
[ "$N" -gt 70 ] || fail "suite list not found in the script ($N)"
fresh() { cp "$SRC" "$R/scripts/laco-check.sh"; touch "$R/scripts/test-laco-check.sh"; }
run() { rm -rf "$FAKE"; mkdir -p "$FAKE"; set +e; "$R/scripts/laco-check.sh" "$@" >"$T/out" 2>"$T/err"; rc=$?; set -e; }
ran() { sort "$FAKE/ran" 2>/dev/null | tr '\n' ' '; }
want() { tr ' ' '\n' <<< "$*" | grep . | sort -u | tr '\n' ' '; }
nfilters() { grep -o -- '--filter' "$FAKE/args" | wc -l | tr -d ' '; }

# a case with area: only area + smoke, each filter anchored, AskTests does not pull RemoteAskTests
fresh; run M11.1; [ "$rc" = 0 ] || fail "M11.1 should pass: $(cat "$T/err")"
[ "$(ran)" = "$(want AskClockTests AskTests RemoteAskTests AskSubmitRetryTests $SMOKE)" ] || fail "area + smoke only, got: $(ran)"
[ "$(nfilters)" = 9 ] || fail "9 filters, got $(nfilters): $(cat "$FAKE/args")"
grep -qxF '\.AskTests/ -> AskTests' "$FAKE/matches" || fail "anchored AskTests: $(cat "$FAKE/matches")"
grep -qF -- '--filter \.WorkLoopTests/' "$FAKE/args" || fail "smoke filter anchored: $(cat "$FAKE/args")"
grep -qF -- '--skip MemoryEventEmissionTests' "$FAKE/args" || fail "keeps the skip"
[ "$(wc -l < "$FAKE/args")" -eq 1 ] || fail "one swift test run"
grep -q 'área + fumaça (9 suítes)' "$T/err" || fail "says what it runs: $(cat "$T/err")"
# an empty area runs the smoke only
run M11.4; [ "$rc" = 0 ] && [ "$(ran)" = "$(want $SMOKE)" ] || fail "empty area = smoke, got: $(ran) $(cat "$T/err")"

# a case without area runs the whole cumulative list; --full and LACO_FULL=1 too, even for a case with area
run M1b.1; [ "$rc" = 0 ] && [ "$(nfilters)" = "$N" ] || fail "no area = all $N, got $(nfilters) $(cat "$T/err")"
run --full M11.1; [ "$rc" = 0 ] && [ "$(nfilters)" = "$N" ] || fail "--full = all, got $(nfilters)"
LACO_FULL=1 run M11.1; [ "$rc" = 0 ] && [ "$(nfilters)" = "$N" ] || fail "LACO_FULL=1 = all, got $(nfilters)"
run --full; [ "$rc" = 0 ] && [ "$(nfilters)" = "$N" ] || fail "--full without task = all, got $(nfilters) $(cat "$T/err")"
[ "$(ran)" = "$(want $SUITES)" ] || fail "--full ran every suite"
[ ! -s "$FAKE/unmatched" ] || fail "no filter matched nothing: $(cat "$FAKE/unmatched")"
run; [ "$rc" = 2 ] || fail "no task and no --full is a usage error"
run M99.9; [ "$rc" = 2 ] && grep -q 'tarefa desconhecida' "$T/err" || fail "unknown task"
rm "$R/Tests/CollieDaemonKitTests/AskClockTests.swift"; run M11.1; [ "$rc" != 0 ] && grep -q 'falta .*AskClockTests.swift' "$T/err" || fail "need"
printf '@Suite struct AskClockTests {}\n' > "$R/Tests/CollieDaemonKitTests/AskClockTests.swift"

# a name with no suite fails before running anything, in the list and in an area
sed -i '' 's/ CommandsTests WorkPanelTests/ CommandsTests NoSuchTests WorkPanelTests/' "$R/scripts/laco-check.sh"
run M1b.1; [ "$rc" != 0 ] || fail "unknown name must fail"
grep -qx 'filtro sem suíte: NoSuchTests' "$T/err" || fail "names it: $(cat "$T/err")"
[ ! -e "$FAKE/args" ] || fail "nothing runs with a bad filter"
run M11.1; [ "$rc" = 0 ] || fail "an area case does not depend on unrelated names of the full list"
# pasted names (the real false negative: two suites glued in one word)
fresh; sed -i '' 's/ LoopSectionTests ContextPanelLoopsTests / LoopSectionTestsContextPanelLoopsTests /' "$R/scripts/laco-check.sh"
grep -q LoopSectionTestsContextPanelLoopsTests "$R/scripts/laco-check.sh" || fail "test setup: glue"
run --full; [ "$rc" != 0 ] && grep -qx 'filtro sem suíte: LoopSectionTestsContextPanelLoopsTests' "$T/err" || fail "pasted names: $(cat "$T/err")"
fresh; sed -i '' 's/area=(AskClockTests AskTests /area=(AskClockTests AskTestsRemoteAskTests /' "$R/scripts/laco-check.sh"
run M11.1; [ "$rc" != 0 ] && grep -qx 'filtro sem suíte: AskTestsRemoteAskTests' "$T/err" || fail "pasted in area: $(cat "$T/err")"
# a prefix of a real suite is no suite (AskTest would match AskTests unanchored)
fresh; sed -i '' 's/area=(AskClockTests AskTests /area=(AskClockTests AskTest /' "$R/scripts/laco-check.sh"
run M11.1; [ "$rc" != 0 ] && grep -qx 'filtro sem suíte: AskTest' "$T/err" || fail "prefix is no suite: $(cat "$T/err")"

# without a build (swift test list fails), the declarations in Tests/ decide
fresh; FAKE_NOLIST=1 run M11.1; [ "$rc" = 0 ] || fail "falls back to Tests/: $(cat "$T/err")"
sed -i '' 's/area=(AskClockTests /area=(AskClockTests GoneTests /' "$R/scripts/laco-check.sh"
FAKE_NOLIST=1 run M11.1; [ "$rc" != 0 ] && grep -qx 'filtro sem suíte: GoneTests' "$T/err" || fail "fallback still rejects"

# the fake is strict: unanchored AskTests matches RemoteAskTests too, a name that matches nothing is recorded
rm -rf "$FAKE"; mkdir -p "$FAKE"; (cd "$R" && swift test --filter AskTests --filter Nope >/dev/null) || true
grep -qxF 'AskTests -> AskTests RemoteAskTests' "$FAKE/matches" && grep -qx Nope "$FAKE/unmatched" || fail "fake rule: $(cat "$FAKE/matches")"

# retry: once, only the failed suites, and it prints which and how long; a real failure keeps the short note
fresh; rm -rf "$FAKE"; mkdir -p "$FAKE"; touch "$FAKE/flaky-AskTests"
set +e; "$R/scripts/laco-check.sh" M11.1 >"$T/out" 2>"$T/err"; rc=$?; set -e
[ "$rc" = 0 ] || fail "flaky suite passes on the retry: $(cat "$T/err")"
grep -q 'repetindo uma vez as suítes que falharam: AskTests ===' "$T/err" || fail "names the retried: $(cat "$T/err")"
grep -qE 'repetição: AskTests: [0-9]+s, passou' "$T/err" || fail "prints the retry time: $(cat "$T/err")"
[ "$(wc -l < "$FAKE/args")" -eq 2 ] && tail -n 1 "$FAKE/args" | grep -qE -- '--filter \\\.AskTests/$' || fail "retry runs only AskTests anchored: $(cat "$FAKE/args")"
rm -rf "$FAKE"; mkdir -p "$FAKE"; touch "$FAKE/broken-AskTests"
set +e; "$R/scripts/laco-check.sh" M11.1 >"$T/out" 2>"$T/err"; rc=$?; set -e
[ "$rc" != 0 ] || fail "a broken suite fails"
grep -qE 'repetição: AskTests: [0-9]+s, falhou de novo' "$T/err" || fail "says it failed again: $(cat "$T/err")"
grep -q '=== falhas (laco-check) ===' "$T/out" && grep -q '✘ Suite AskTests' "$T/out" && grep -q 'Test run with' "$T/out" || fail "short note: $(cat "$T/out")"
[ "$(wc -l < "$FAKE/args")" -eq 2 ] || fail "retries once"

echo "test-laco-check: ok"
