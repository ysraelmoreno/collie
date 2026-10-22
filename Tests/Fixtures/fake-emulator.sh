#!/bin/sh
# Fake Android emulator for tests. `-list-avds` cats $ORQ_FAKE_EMULATOR_AVDS. `-avd <name> …` appends "launch <name> $$" to
# $ORQ_FAKE_EMULATOR_LOG; with $ORQ_FAKE_EMULATOR_FAIL it prints a FATAL line and exits 1; otherwise it sleeps
# ${ORQ_FAKE_EMULATOR_DELAY:-0} s, adds $ORQ_FAKE_EMULATOR_SERIAL to the fake adb's devices file, records "<serial> <name>"
# in $ORQ_FAKE_ADB_AVDNAMES and becomes `sleep 600` (Orq must leave it running).
if [ "$1" = "-list-avds" ]; then cat "$ORQ_FAKE_EMULATOR_AVDS"; exit 0; fi
if [ "$1" = "-avd" ]; then
  [ -n "$ORQ_FAKE_EMULATOR_LOG" ] && echo "launch $2 $$" >> "$ORQ_FAKE_EMULATOR_LOG"
  if [ -n "$ORQ_FAKE_EMULATOR_FAIL" ]; then echo "FATAL | broken AVD"; exit 1; fi
  sleep "${ORQ_FAKE_EMULATOR_DELAY:-0}"
  echo "$ORQ_FAKE_EMULATOR_SERIAL device product:sdk model:$2" >> "$ORQ_FAKE_ADB_DEVICES"
  echo "$ORQ_FAKE_EMULATOR_SERIAL $2" >> "$ORQ_FAKE_ADB_AVDNAMES"
  exec sleep 600
fi
exit 0
