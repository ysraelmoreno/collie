#!/bin/sh
# Fake coding agent for tests: answers each input line; ORQ_FAKE_HOOK=1 prints a stop marker.
# ORQ_FAKE_HOOK_DELAY=<s> sleeps that long after the answer before the hook (a hook slower than idle detection).
# ORQ_FAKE_HOOK_FROM=<n> sends hooks only from turn n on (a terminal that starts hooking mid-session).
# ORQ_FAKE_HOOK_SKIP=<n> sends no hook for turn n (a lost hook, e.g. an interrupted turn).
# ORQ_FAKE_HOOK=file appends each hook message to $ORQ_FAKE_HOOK_FILE instead (off-screen, like a real hook).
# ORQ_FAKE_HOOK_DECOR=<s> wraps the hook message in <s> (a hook message that differs from the screen text).
# Prints a banner first, like a real agent/shell: orqd injects nothing until a terminal has printed something.
echo "fake-agent ready"
turn=0
while IFS= read -r line; do
  turn=$((turn + 1))
  echo "thinking..."
  sleep 0.5
  echo "answer:$line"
  if [ -n "$ORQ_FAKE_HOOK_DELAY" ]; then sleep "$ORQ_FAKE_HOOK_DELAY"; fi
  if [ "$turn" -lt "${ORQ_FAKE_HOOK_FROM:-1}" ]; then continue; fi
  if [ "$turn" = "${ORQ_FAKE_HOOK_SKIP:-0}" ]; then continue; fi
  if [ "$ORQ_FAKE_HOOK" = "cli" ]; then "${ORQ_CLI_PATH:-orq}" hook generic-stop --message "answer:$line"; fi
  if [ "$ORQ_FAKE_HOOK" = "file" ]; then printf '%s\n' "${ORQ_FAKE_HOOK_DECOR}answer:$line${ORQ_FAKE_HOOK_DECOR}" >> "$ORQ_FAKE_HOOK_FILE"; fi
  if [ "$ORQ_FAKE_HOOK" = "1" ]; then echo "<<ORQ_FAKE_STOP:${ORQ_FAKE_HOOK_DECOR}answer:$line${ORQ_FAKE_HOOK_DECOR}>>"; fi
done
