#!/bin/sh
# Fake coding agent for tests: answers each input line; COLLIE_FAKE_HOOK=1 prints a stop marker.
# COLLIE_FAKE_HOOK_DELAY=<s> sleeps that long after the answer before the hook (a hook slower than idle detection).
# COLLIE_FAKE_HOOK_FROM=<n> sends hooks only from turn n on (a terminal that starts hooking mid-session).
# COLLIE_FAKE_HOOK_SKIP=<n> sends no hook for turn n (a lost hook, e.g. an interrupted turn).
# COLLIE_FAKE_HOOK=file appends each hook message to $COLLIE_FAKE_HOOK_FILE instead (off-screen, like a real hook).
# COLLIE_FAKE_HOOK_DECOR=<s> wraps the hook message in <s> (a hook message that differs from the screen text).
# Prints a banner first, like a real agent/shell: collied injects nothing until a terminal has printed something.
echo "fake-agent ready"
turn=0
while IFS= read -r line; do
  turn=$((turn + 1))
  echo "thinking..."
  sleep 0.5
  echo "answer:$line"
  if [ -n "$COLLIE_FAKE_HOOK_DELAY" ]; then sleep "$COLLIE_FAKE_HOOK_DELAY"; fi
  if [ "$turn" -lt "${COLLIE_FAKE_HOOK_FROM:-1}" ]; then continue; fi
  if [ "$turn" = "${COLLIE_FAKE_HOOK_SKIP:-0}" ]; then continue; fi
  if [ "$COLLIE_FAKE_HOOK" = "cli" ]; then "${COLLIE_CLI_PATH:-collie}" hook generic-stop --message "answer:$line"; fi
  if [ "$COLLIE_FAKE_HOOK" = "file" ]; then printf '%s\n' "${COLLIE_FAKE_HOOK_DECOR}answer:$line${COLLIE_FAKE_HOOK_DECOR}" >> "$COLLIE_FAKE_HOOK_FILE"; fi
  if [ "$COLLIE_FAKE_HOOK" = "1" ]; then echo "<<COLLIE_FAKE_STOP:${COLLIE_FAKE_HOOK_DECOR}answer:$line${COLLIE_FAKE_HOOK_DECOR}>>"; fi
done
