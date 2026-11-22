#!/bin/bash
# Stress of the helper's accessibility service (regression of the blindness, README "Regressão da cegueira").
set -euo pipefail
usage() {
  cat <<'EOF'
Uso: Helpers/android-device/stress-toggle.sh <serial> [rodadas=6]

Liga e desliga o serviço de acessibilidade do helper (com.collie.helper/.HelperService) por
`settings put secure enabled_accessibility_services`, acrescentando e tirando só ele (serviços alheios ficam),
e mede os nós do `dump` em cada rodada por dois procedimentos:
  A) sonda tardia: espera 3 s depois de ligar e faz um dump;
  B) sondagem a cada 300 ms desde o instante de ligar: tempo até o dump ter nós (cega se nada em 5 s).
Saída: uma linha por rodada e um resumo (rodadas cegas de A, tempo mediano de B).
A lista original de serviços (e accessibility_enabled) volta ao sair, também em erro ou Ctrl-C.
Esperado: A alterna saudável/cega; B sempre saudável em < 1 s.
Ambiente: ADB (caminho do adb), PROBE (sonda; padrão helper-probe.py ao lado deste script).
Exit 2: sem adb ou sem aparelho.
EOF
}
case "${1:-}" in -h|--help) usage; exit 0 ;; "") usage >&2; exit 2 ;; esac
SER="$1"; ROUNDS="${2:-6}"
[[ "$ROUNDS" =~ ^[1-9][0-9]*$ ]] || { echo "rodadas inválidas: $ROUNDS" >&2; exit 2; }
SVC="com.collie.helper/com.collie.helper.HelperService"   # the long form Android stores; the short form (.HelperService) is the same service
PROBE="${PROBE:-python3 $(cd "$(dirname "$0")" && pwd)/helper-probe.py}"
ADB="${ADB:-$(command -v adb || echo "$HOME/Library/Android/sdk/platform-tools/adb")}"
[ -x "$ADB" ] || { echo "adb não encontrado (defina ADB ou ponha o adb no PATH)" >&2; exit 2; }
[ "$("$ADB" -s "$SER" get-state 2>/dev/null)" = device ] || { echo "aparelho $SER não está conectado (adb devices)" >&2; exit 2; }

a() { "$ADB" -s "$SER" "$@"; }
get() { a shell settings get secure "$1" | tr -d '\r'; }
# Values go through the device shell: single-quoted so a `$` in a service name survives.
put() { if [ -z "$2" ] || [ "$2" = null ]; then a shell settings delete secure "$1" >/dev/null; else a shell "settings put secure $1 '$2'"; fi; }
ORIG="$(get enabled_accessibility_services)"; ORIG_ON="$(get accessibility_enabled)"
PORT=""
restore() {
  put enabled_accessibility_services "$ORIG" || true; put accessibility_enabled "$ORIG_ON" || true
  [ -n "$PORT" ] && a forward --remove "tcp:$PORT" >/dev/null 2>&1 || true
}
trap restore EXIT; trap 'exit 130' INT TERM
# Others: the original list without the helper (null/empty: none).
OTHERS="$(tr ':' '\n' <<<"$ORIG" | grep -v -e '^com\.collie\.helper/' -e '^null$' -e '^$' | paste -sd: - || true)"
off() { put enabled_accessibility_services "$OTHERS"; put accessibility_enabled 0; sleep 2; }   # accessibility_enabled 0 and 2 s: what reproduced the blindness by hand (1 s with it left on did not)
on() { put enabled_accessibility_services "${OTHERS:+$OTHERS:}$SVC"; put accessibility_enabled 1; }
PORT="$(a forward tcp:0 localabstract:collie-helper | tr -d '\r')"   # adb picks a free port and prints it

blind=0; times=()
for ((i = 1; i <= ROUNDS; i++)); do
  off; on; sleep 3; na="$($PROBE --nodes "$PORT")"
  off; on; tb="$($PROBE --wait "$PORT")"
  [ "$na" -gt 0 ] && ra="saudável ($na nós)" || { ra="CEGA"; blind=$((blind + 1)); }
  [ "$tb" -ge 0 ] && { rb="saudável em $tb ms"; times+=("$tb"); } || rb="CEGA em 5 s"
  echo "rodada $i/$ROUNDS: A $ra · B $rb"
done
if [ ${#times[@]} -gt 0 ]; then
  med="$(printf '%s\n' "${times[@]}" | sort -n | awk '{v[NR]=$1} END{print (NR%2 ? v[(NR+1)/2] : int((v[NR/2]+v[NR/2+1])/2))}') ms"
else med="—"; fi
echo "resumo: A cega em $blind/$ROUNDS rodadas · B mediana $med ($(( ROUNDS - ${#times[@]} )) cegas)"
