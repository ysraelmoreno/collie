#!/bin/sh
# Fake adb for tests. Logs each invocation (args joined by tab) to $ORQ_FAKE_ADB_LOG.
# `devices -l` prints the file $ORQ_FAKE_ADB_DEVICES; screencap cats $ORQ_FAKE_ADB_PNG; `cat /sdcard/orq-ui.xml`
# cats $ORQ_FAKE_ADB_UI; screencap first sleeps $ORQ_FAKE_ADB_SLEEP seconds when set; `logcat -d` cats $ORQ_FAKE_ADB_LOGCAT; install prints Success; monkey prints Events injected.
# `shell date +%s` prints 1700000000; `logcat -b crash` appends $$ to $ORQ_FAKE_ADB_PIDS, prints $ORQ_FAKE_ADB_CRASH
# (when set) and sleeps 600 s (the watcher must kill the group).
# `emu avd name` prints the name for the serial from $ORQ_FAKE_ADB_AVDNAMES (lines `<serial> <name>`) then OK (OK first with $ORQ_FAKE_ADB_OK_FIRST), else exits 1;
# `shell getprop sys.boot_completed` prints ${ORQ_FAKE_ADB_BOOTED:-1}.
# scrcpy: `push` and `forward --remove` are only logged; `forward tcp:0 …` prints $ORQ_FAKE_ADB_PORT; `shell CLASSPATH=…`
# (the server) appends "scrcpy $$" to $ORQ_FAKE_ADB_PIDS (apart from the crash watchers' bare pids) and becomes `sleep 600`.
if [ -n "$ORQ_FAKE_ADB_LOG" ]; then
  s=""; for a in "$@"; do if [ -z "$s" ]; then s="$a"; else s="$s	$a"; fi; done
  printf '%s\n' "$s" >> "$ORQ_FAKE_ADB_LOG"
fi
SERIAL=""
if [ "$1" = "-s" ]; then SERIAL="$2"; shift 2; fi
case "$1 $2 $3" in
  "devices -l "*) cat "$ORQ_FAKE_ADB_DEVICES" ;;
  "exec-out screencap -p") [ -n "$ORQ_FAKE_ADB_SLEEP" ] && sleep "$ORQ_FAKE_ADB_SLEEP"; cat "$ORQ_FAKE_ADB_PNG" ;;
  "exec-out cat /sdcard/orq-ui.xml") cat "$ORQ_FAKE_ADB_UI" ;;
  "logcat -d -t") cat "$ORQ_FAKE_ADB_LOGCAT" ;;
  "install -r "*) echo Success ;;
  "shell monkey -p") echo "Events injected: 1" ;;
  "emu avd name") n=$(grep "^$SERIAL " "$ORQ_FAKE_ADB_AVDNAMES" 2>/dev/null | head -1 | cut -d' ' -f2-); [ -n "$n" ] || exit 1; [ -n "$ORQ_FAKE_ADB_OK_FIRST" ] && echo OK; echo "$n"; [ -z "$ORQ_FAKE_ADB_OK_FIRST" ] && echo OK; exit 0 ;;
  "shell getprop sys.boot_completed") echo "${ORQ_FAKE_ADB_BOOTED:-1}" ;;
  "shell date +%s") echo 1700000000 ;;
  "forward tcp:0 "*) echo "$ORQ_FAKE_ADB_PORT" ;;
  "shell CLASSPATH="*)
    [ -n "$ORQ_FAKE_ADB_PIDS" ] && echo "scrcpy $$" >> "$ORQ_FAKE_ADB_PIDS"
    exec sleep 600 ;;
  "logcat -b crash")
    [ -n "$ORQ_FAKE_ADB_PIDS" ] && echo $$ >> "$ORQ_FAKE_ADB_PIDS"
    [ -n "$ORQ_FAKE_ADB_CRASH" ] && printf '%s\n' "$ORQ_FAKE_ADB_CRASH"
    sleep 600 ;;
esac
exit 0
