#!/bin/sh
# Puts this checkout into the installed Collie (DX backlog 12): a daemon/app fix reaches the running Collie.
#
#   scripts/dev/reload.sh            bundle (scripts/bundle-app.sh), quit the app, replace the installed bundle,
#                                    restart collied (launchctl kickstart -k), open the app again
#   scripts/dev/reload.sh --dry-run  print the steps, change nothing
#
# Restarting collied ends every terminal's process; the daemon relaunches them (Claude resumes its conversation).
# From inside a Collie terminal the swap runs detached (this terminal goes down with the daemon): log in $LOG.
# APP: $COLLIE_APP, default /Applications/Collie.app. LABEL: $COLLIE_LABEL, default dev.collie.daemon.
set -eu
here=$(cd "$(dirname "$0")/../.." && pwd)
APP=${COLLIE_APP:-/Applications/Collie.app}
LABEL=${COLLIE_LABEL:-dev.collie.daemon}
LOG=${TMPDIR:-/tmp}/collie-reload.log
DRY=0
run() { if [ $DRY = 1 ]; then echo "+ $*"; else "$@"; fi }

swap() {   # the bundle is built: quit, replace, restart, reopen
  run osascript -e 'quit app "Collie"'
  i=0; while [ $DRY = 0 ] && pgrep -xq Collie; do
    i=$((i+1)); [ $i -gt 50 ] && { echo "reload: Collie did not quit" >&2; exit 1; }; sleep 0.2
  done
  run rsync -a --delete "$here/build/Collie.app/" "$APP/"
  run launchctl kickstart -k "gui/$(id -u)/$LABEL"
  run open "$APP"
  [ $DRY = 1 ] || echo "reload: $APP replaced, collied restarted, app reopened"
}

case ${1:-} in
--swap) swap; exit 0 ;;   # the detached half
--dry-run) DRY=1 ;;
"") ;;
*) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
[ -d "$APP" ] || { echo "reload: no installed Collie at $APP (set COLLIE_APP)" >&2; exit 1; }
run "$here/scripts/bundle-app.sh"
[ $DRY = 1 ] || [ -d "$here/build/Collie.app" ] || { echo "reload: bundle-app.sh made no build/Collie.app" >&2; exit 1; }
if [ $DRY = 0 ] && [ -n "${COLLIE_TERMINAL_ID:-}" ]; then
  echo "reload: inside a Collie terminal: the swap goes on detached (log: $LOG); this terminal restarts with the daemon"
  nohup "$0" --swap > "$LOG" 2>&1 < /dev/null &
else
  swap
fi
