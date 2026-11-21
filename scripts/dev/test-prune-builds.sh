#!/usr/bin/env bash
# Tests of prune-builds.sh in a temporary folder: dry-run removes nothing, --apply --older-than only the old,
# nothing outside .build/ (a symlink out), never a live terminal's folder, an odd argument is an error.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
B="$T/repo/.build"; mkdir -p "$B"/{debug,checkouts,old-agent,new-agent,laco-w-task-f1,laco-w-task} "$T/outside"
echo x > "$B/old-agent/f"; echo x > "$T/outside/keep"; echo '{}' > "$B/workspace-state.json"
ln -s "$T/outside" "$B/evil"
old=$(date -v-30d +%Y%m%d%H%M)
touch -t "$old" "$B/old-agent" "$B/debug" "$B/checkouts" "$B/laco-w-task-f1" "$B/laco-w-task" "$T/outside"
mkdir -p "$T/bin"; printf '#!/bin/sh\nprintf "w-task-f1-t2\\tclaude\\trunning\\n"\n' > "$T/bin/collie"; chmod +x "$T/bin/collie"
run() { PATH="$T/bin:$PATH" PRUNE_ROOT="$T/repo" "$here/prune-builds.sh" "$@"; }

out=$(run); echo "$out" | grep -q "keep   old-agent" || fail "dry-run lists: $out"
[ -d "$B/old-agent" ] || fail "dry-run removed"
echo "$out" | grep -q "debug\|checkouts\|workspace-state" && fail "lists SwiftPM's own: $out"

out=$(run --apply --older-than 7)
[ ! -e "$B/old-agent" ] || fail "old not removed: $out"
[ -d "$B/new-agent" ] || fail "new removed"
[ -d "$B/laco-w-task-f1" ] || fail "live terminal's folder removed: $out"
[ ! -e "$B/laco-w-task" ] || fail "dead loop folder kept: $out"
[ -d "$B/debug" ] && [ -d "$B/checkouts" ] && [ -f "$B/workspace-state.json" ] || fail "SwiftPM's own removed"
[ -f "$T/outside/keep" ] && [ -L "$B/evil" ] || fail "followed a path outside .build/"
echo "$out" | grep -q "skip   evil" || fail "symlink out not refused: $out"

run --bogus 2>/dev/null && fail "odd argument accepted"
run --apply 2>/dev/null && fail "--apply without --older-than accepted"
run --apply --older-than x 2>/dev/null && fail "non-numeric days accepted"
echo "test-prune-builds: ok"
