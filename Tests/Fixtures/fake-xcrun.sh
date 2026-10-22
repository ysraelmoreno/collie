#!/bin/sh
# Fake xcrun for tests. Logs each invocation (args joined by tab) to $ORQ_FAKE_XCRUN_LOG.
# `simctl list devices -j` cats $ORQ_FAKE_SIM_DEVICES (unset: exits 1, as if Xcode were missing); `simctl io S screenshot P`
# copies $ORQ_FAKE_ADB_PNG to P; `simctl spawn S log show …` cats $ORQ_FAKE_SIM_LOG ($ORQ_FAKE_SIM_LOG30 for --last 30s, when set); launch prints "<id>: 123";
# bootstatus and install are only logged.
if [ -n "$ORQ_FAKE_XCRUN_LOG" ]; then
  s=""; for a in "$@"; do if [ -z "$s" ]; then s="$a"; else s="$s	$a"; fi; done
  printf '%s\n' "$s" >> "$ORQ_FAKE_XCRUN_LOG"
fi
[ "$1" = "simctl" ] || exit 1
case "$2" in
  list) [ -n "$ORQ_FAKE_SIM_DEVICES" ] || exit 1; cat "$ORQ_FAKE_SIM_DEVICES" ;;
  io) cp "$ORQ_FAKE_ADB_PNG" "$5" ;;
  spawn) f="$ORQ_FAKE_SIM_LOG"; [ "$7" = 30s ] && [ -n "$ORQ_FAKE_SIM_LOG30" ] && f="$ORQ_FAKE_SIM_LOG30"; cat "$f" ;;
  launch) echo "$4: 123" ;;
esac
exit 0
