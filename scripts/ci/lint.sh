#!/bin/bash
# Ratchet lint: per-file counts of risky patterns in Sources/ may only go down (scripts/ci/lint-baseline.txt).
# Usage: scripts/ci/lint.sh [--update-baseline]. LINT_ROOT overrides the repo root (used by test-lint.sh).
set -euo pipefail
export LC_ALL=C
ROOT="${LINT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
BASE="$ROOT/scripts/ci/lint-baseline.txt"
NAMES=(sleep unsafe-concurrency force)
REGEX=('Task\.sleep|\.asyncAfter\(|usleep\(|Thread\.sleep|\.sleep\((for|until):' '@unchecked Sendable|nonisolated\(unsafe\)' 'try!|as! ')
CAUSE=("espere o evento (continuation, AsyncStream, notificação, hook), não o tempo"
       "isole o estado num actor ou torne o tipo Sendable de verdade"
       "trate o erro; um regex constante vira static let com try num inicializador testado")
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cd "$ROOT"
: > "$T/cur"
for i in "${!NAMES[@]}"; do
  grep -rcE --include='*.swift' -- "${REGEX[$i]}" Sources 2>/dev/null \
    | awk -F: -v r="${NAMES[$i]}" '{n=$NF; sub(/:[0-9]+$/,""); if (n>0) print r" "$0" "n}' >> "$T/cur" || true
done
sort -o "$T/cur" "$T/cur"
[ -f "$BASE" ] || : > "$BASE"
# over: not in baseline or above it; under: baseline has more than the tree
awk 'FILENAME==ARGV[1]{b[$1" "$2]=$3;next} {k=$1" "$2; if(!(k in b)||$3>b[k]) print}' "$BASE" "$T/cur" > "$T/over"
awk 'FILENAME==ARGV[1]{c[$1" "$2]=$3;next} {k=$1" "$2; if(!(k in c)||c[k]<$3) print}' "$T/cur" "$BASE" > "$T/under"

if [ "${1:-}" = "--update-baseline" ]; then
  if [ -s "$T/over" ]; then echo "lint: --update-baseline só abaixa números; há ocorrências novas (veja sem a flag). Subir é edição à mão do baseline." >&2; exit 1; fi
  cp "$T/cur" "$BASE"; echo "lint: baseline atualizado"; exit 0
fi

rc=0
# feature-map: every panel is named in docs/feature-map.md. No baseline: there is no exception.
for f in Sources/ColliePlugins/*Panel.swift; do
  [ -f "$f" ] || continue
  n="$(basename "$f" .swift)"
  grep -qw -- "$n" docs/feature-map.md 2>/dev/null && continue
  echo "lint: regra 'feature-map': $f não está em docs/feature-map.md. Acrescente em \"Painéis\" uma seção que cite $n (nome na UI, para que serve, arquivos, como verificar)." >&2
  rc=1
done
if [ -s "$T/over" ]; then
  while read -r rule file n; do
    for i in "${!NAMES[@]}"; do [ "${NAMES[$i]}" = "$rule" ] && break; done
    echo "lint: regra '$rule' em $file passou do baseline (agora $n)." >&2
    grep -nE -- "${REGEX[$i]}" "$file" | sed "s#^#  $file:#" >&2
    echo "  causa raiz a atacar: ${CAUSE[$i]}" >&2
  done < "$T/over"
  rc=1
fi
if [ -s "$T/under" ]; then
  echo "lint: o código tem menos ocorrências que o baseline (catraca). Rode scripts/ci/lint.sh --update-baseline e commite:" >&2
  sed 's/^/  /' "$T/under" >&2
  rc=1
fi
[ "$rc" = 0 ] && echo "lint ok"
exit $rc
