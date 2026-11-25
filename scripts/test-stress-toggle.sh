#!/bin/bash
# Checks Helpers/android-device/stress-toggle.sh without a device: a fake adb keeps the settings in files, a fake probe answers.
set -euo pipefail
cd "$(dirname "$0")/.."
S=Helpers/android-device/stress-toggle.sh
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
PATH=/usr/bin:/bin $S --help | grep -q rodadas || fail "--help"
set +e
ADB="$T/none" $S emulator-5554 2>"$T/e"; rc=$?; set -e
[ $rc = 2 ] && grep -q "adb não encontrado" "$T/e" || fail "sem adb: rc=$rc"
cat > "$T/adb" <<'A'
#!/bin/bash
D="$(dirname "$0")"; shift 2; echo "$*" >> "$D/log"
case "$1" in
  get-state) [ -f "$D/online" ] && echo device || exit 1 ;;
  forward) [ "$2" = --remove ] || echo 51234 ;;
  shell) set -- $*; shift
    if [ "$1 $2" = "settings get" ]; then cat "$D/$4" 2>/dev/null || echo null
    elif [ "$1 $2" = "settings delete" ]; then rm -f "$D/$4"
    else v="${5#\'}"; printf '%s\n' "${v%\'}" > "$D/$4"; fi ;;
esac
A
chmod +x "$T/adb"
set +e; ADB="$T/adb" $S emulator-5554 2>"$T/e"; rc=$?; set -e
[ $rc = 2 ] && grep -q "não está conectado" "$T/e" || fail "sem aparelho: rc=$rc"
touch "$T/online"; echo 'a.b/.Other$X:com.collie.helper/.HelperService' > "$T/enabled_accessibility_services"
echo 0 > "$T/accessibility_enabled"
printf '#!/bin/bash\n[ "$1" = --nodes ] && echo 0 || echo 420\n' > "$T/probe"; chmod +x "$T/probe"
out="$(ADB="$T/adb" PROBE="$T/probe" $S emulator-5554 1)"
grep -q "rodada 1/1: A CEGA · B saudável em 420 ms" <<<"$out" || fail "rodada: $out"
grep -q "A cega em 1/1 rodadas · B mediana 420 ms" <<<"$out" || fail "resumo: $out"
grep -q "settings put secure enabled_accessibility_services 'a.b/.Other\$X:com.collie.helper/.HelperService'" "$T/log" || fail "não ligou acrescentando"
grep -q "settings put secure enabled_accessibility_services 'a.b/.Other\$X'$" "$T/log" || fail "desligar apagou alheios"
[ "$(cat "$T/enabled_accessibility_services")" = 'a.b/.Other$X:com.collie.helper/.HelperService' ] || fail "lista não restaurada"
[ "$(cat "$T/accessibility_enabled")" = 0 ] || fail "accessibility_enabled não restaurado"
grep -q "forward --remove tcp:51234" "$T/log" || fail "forward não removido"
echo ok
