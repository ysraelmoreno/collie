#!/bin/sh
# Fake AXe for tests. Logs each invocation (args joined by tab) to $COLLIE_FAKE_AXE_LOG.
# `describe-ui` cats Fixtures/ios/describe-ui.json. `stream-video` appends "axe $$" to $COLLIE_FAKE_AXE_PIDS and cats
# Fixtures/ios/stream.mjpeg (3 frames) every 0.1 s until killed, or $COLLIE_FAKE_AXE_FRAMES times and exits when set.
# Everything else exits 0, after sleeping $COLLIE_FAKE_AXE_SLEEP seconds when set.
if [ -n "$COLLIE_FAKE_AXE_LOG" ]; then
  s=""; for a in "$@"; do if [ -z "$s" ]; then s="$a"; else s="$s	$a"; fi; done
  printf '%s\n' "$s" >> "$COLLIE_FAKE_AXE_LOG"
fi
case "$1" in
  describe-ui) cat "$(dirname "$0")/ios/describe-ui.json" ;;
  stream-video)
    [ -n "$COLLIE_FAKE_AXE_PIDS" ] && echo "axe $$" >> "$COLLIE_FAKE_AXE_PIDS"
    n=0
    while [ -z "$COLLIE_FAKE_AXE_FRAMES" ] || [ "$n" -lt "$COLLIE_FAKE_AXE_FRAMES" ]; do
      cat "$(dirname "$0")/ios/stream.mjpeg"; n=$((n + 1)); sleep 0.1
    done ;;
  *) [ -n "$COLLIE_FAKE_AXE_SLEEP" ] && sleep "$COLLIE_FAKE_AXE_SLEEP" ;;
esac
exit 0
