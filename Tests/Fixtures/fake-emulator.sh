#!/bin/sh
# Fake Android emulator for tests. `-list-avds` cats $COLLIE_FAKE_EMULATOR_AVDS. `-avd <name> …` appends "launch <name> $$" to
# $COLLIE_FAKE_EMULATOR_LOG; with $COLLIE_FAKE_EMULATOR_FAIL it prints a FATAL line and exits 1; otherwise it sleeps
# ${COLLIE_FAKE_EMULATOR_DELAY:-0} s, adds $COLLIE_FAKE_EMULATOR_SERIAL to the fake adb's devices file, records "<serial> <name>"
# in $COLLIE_FAKE_ADB_AVDNAMES and becomes `sleep 600` (Collie must leave it running).
if [ "$1" = "-list-avds" ]; then cat "$COLLIE_FAKE_EMULATOR_AVDS"; exit 0; fi
if [ "$1" = "-avd" ]; then
  [ -n "$COLLIE_FAKE_EMULATOR_LOG" ] && echo "launch $2 $$" >> "$COLLIE_FAKE_EMULATOR_LOG"
  if [ -n "$COLLIE_FAKE_EMULATOR_FAIL" ]; then echo "FATAL | broken AVD"; exit 1; fi
  sleep "${COLLIE_FAKE_EMULATOR_DELAY:-0}"
  echo "$COLLIE_FAKE_EMULATOR_SERIAL device product:sdk model:$2" >> "$COLLIE_FAKE_ADB_DEVICES"
  echo "$COLLIE_FAKE_EMULATOR_SERIAL $2" >> "$COLLIE_FAKE_ADB_AVDNAMES"
  exec sleep 600
fi
exit 0
