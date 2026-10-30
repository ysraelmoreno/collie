#!/bin/sh
# A development collied built from this checkout, on its own root and socket, next to the installed Collie (which it
# never touches: different root, no LaunchAgent, no admin.token of the real one).
#
#   scripts/dev/run-isolated.sh start        build (debug) and start collied --root $ROOT in the background
#   scripts/dev/run-isolated.sh cli <args>   run this checkout's `collie` against it, as admin (the user)
#   scripts/dev/run-isolated.sh status       pid, socket, log tail
#   scripts/dev/run-isolated.sh stop         SIGTERM (collied stops captures, restoring their devices), wait for exit
#   scripts/dev/run-isolated.sh env          the exports `cli` uses, to paste into a shell
#
# ROOT: $COLLIE_DEV_ROOT, default /tmp/collie-dev (short on purpose: a Unix socket path must fit in 104 bytes).
# Admin: an unbundled collied on a root other than the default one does not check the app signature, so the dev root's
# admin.token is enough. Inside a Collie terminal every COLLIE_* of the installed daemon is dropped first, otherwise the
# CLI would talk to (and authenticate as a terminal of) the installed daemon.
# The app (DEBUG build) can join it with COLLIE_ROOT=$ROOT COLLIE_LABEL=dev.collie.daemon.isolated .build/debug/CollieApp,
# but it registers that label as a LaunchAgent: not done here.
set -eu
here=$(cd "$(dirname "$0")/../.." && pwd)
ROOT=${COLLIE_DEV_ROOT:-/tmp/collie-dev}
BIN=$here/.build/debug
PID=$ROOT/collied.pid LOG=$ROOT/collied.log SOCK=$ROOT/run/collied.sock

die() { echo "run-isolated: $*" >&2; exit 1; }
running() { [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; }
clean_env() { for v in $(env | sed -n 's/^\(COLLIE_[A-Z0-9_]*\)=.*/\1/p'); do unset "$v"; done; }
isolated_env() {
  clean_env
  export COLLIE_SOCKET="$SOCK" COLLIE_ADMIN_TOKEN_FILE="$ROOT/admin.token"
  COLLIE_TOKEN=$(cat "$ROOT/admin.token"); export COLLIE_TOKEN   # admin: no COLLIE_TERMINAL_ID
}

case ${1:-} in
start)
  running && die "already running (pid $(cat "$PID")); stop it first"
  [ "$(cd "$ROOT" 2>/dev/null && pwd -P)" = "$(cd "$HOME/Library/Application Support/Collie" 2>/dev/null && pwd -P)" ] \
    && die "$ROOT is the installed Collie's root"
  (cd "$here" && swift build --product collied && swift build --product collie) >&2
  mkdir -p "$ROOT" && chmod 700 "$ROOT"
  clean_env
  nohup "$BIN/collied" --root "$ROOT" --no-terminal-sandbox > "$LOG" 2>&1 < /dev/null &
  echo $! > "$PID"
  i=0; until [ -S "$SOCK" ] && [ -s "$ROOT/admin.token" ]; do
    running || { tail -20 "$LOG" >&2; die "collied exited"; }
    i=$((i+1)); [ $i -gt 150 ] && die "no socket at $SOCK after 30 s"; sleep 0.2
  done
  echo "collied dev: pid $(cat "$PID"), root $ROOT, log $LOG" ;;
cli)
  shift; running || die "not running (start it first)"
  isolated_env; exec "$BIN/collie" "$@" ;;
env)
  echo "export COLLIE_SOCKET='$SOCK' COLLIE_ADMIN_TOKEN_FILE='$ROOT/admin.token' COLLIE_TOKEN=\"\$(cat '$ROOT/admin.token')\"; unset COLLIE_TERMINAL_ID" ;;
status)
  if running; then echo "running: pid $(cat "$PID"), socket $SOCK"; else echo "stopped"; fi
  [ -f "$LOG" ] && tail -5 "$LOG" ;;
stop)
  running || { echo "not running"; rm -f "$PID"; exit 0; }
  p=$(cat "$PID"); kill -TERM "$p"
  i=0; while kill -0 "$p" 2>/dev/null; do i=$((i+1)); [ $i -gt 300 ] && { kill -KILL "$p"; echo "killed after 60 s"; break; }; sleep 0.2; done
  rm -f "$PID"; echo "stopped" ;;
*) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
