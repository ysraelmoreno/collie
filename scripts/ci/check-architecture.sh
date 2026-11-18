#!/bin/bash
# Module boundaries, enforced (PRD A3). Two checks over Sources/<target>/**/*.swift:
#   1. declared imports: an `import <M>` where <M> is a target of this package or a product of a dependency
#      (SwiftTerm) must be a DIRECT dependency of the importing target. SwiftPM itself lets transitive ones through.
#   2. the rules in scripts/ci/architecture-rules.txt (format documented there).
# Test targets are not scanned. Apple frameworks and the stdlib only matter to forbid-import rules.
# Usage: scripts/ci/check-architecture.sh [--package-json <file>]
#   --package-json <file>  use this `swift package dump-package` output instead of running swift
#   ARCH_ROOT=<dir>        tree that holds Sources/ and scripts/ci/architecture-rules.txt (default: the repo)
set -euo pipefail

PKG_JSON=""
if [ "${1:-}" = --package-json ]; then
  PKG_JSON="${2:?--package-json precisa de um arquivo}"
  case "$PKG_JSON" in /*) ;; *) PKG_JSON="$PWD/$PKG_JSON" ;; esac
fi
cd "${ARCH_ROOT:-$(dirname "$0")/../..}"
RULES=scripts/ci/architecture-rules.txt

if [ -n "$PKG_JSON" ]; then JSON="$(cat "$PKG_JSON")"; else JSON="$(swift package dump-package)"; fi

DEPS='(.targets | map({key: .name, value: [.dependencies[] | (.byName // .target // .product)[0]]}) | from_entries) as $deps
  | def closure: . as $n | [($deps[$n] // [])[] | (., closure[])] | unique;'
# One line per non-test target: name, source dir, direct deps, dependency closure (`-` when empty, so no field is blank).
TARGETS="$(jq -r "$DEPS"'
  def row: if length == 0 then "-" else join(" ") end;
  .targets[] | select(.type != "test")
  | [.name, (.path // "Sources/\(.name)"), ($deps[.name] | row), (.name | closure | row)] | @tsv' <<<"$JSON")"
# Modules this check knows about: every target of the package plus every product it depends on.
KNOWN=" $(jq -r "$DEPS"' ([.targets[].name] + [$deps[][]]) | unique | join(" ")' <<<"$JSON") "

errors=0
err() { # <file:line> <rule> <message with what to do>
  echo "$1: [$2] $3" >&2
  errors=$((errors + 1))
}
field() { awk -F'\t' -v t="$1" -v n="$2" '$1 == t { print $n; exit }' <<<"$TARGETS"; }

# imports <dir> → one "<module> <file>:<line>" per import statement.
# ponytail: line-based, so an `import X` at the start of a line inside a multi-line string literal counts too;
# switch to swift-syntax only if that ever gives a false positive.
ATTRS='(@[A-Za-z_]+(\([^)]*\))?[[:space:]]+)*((public|package|internal|fileprivate|private)[[:space:]]+)?'
KINDS='((typealias|struct|class|enum|protocol|let|var|func)[[:space:]]+)?'
imports() {
  [ -d "$1" ] || return 0
  { grep -rnE --include='*.swift' "^[[:space:]]*${ATTRS}import[[:space:]]+" "$1" || true; } |
    sed -E "s/^([^:]+:[0-9]+):[[:space:]]*${ATTRS}import[[:space:]]+${KINDS}([A-Za-z_][A-Za-z0-9_]*).*/\8 \1/"
}

# 1. declared imports
while IFS=$'\t' read -r target dir direct _; do
  while read -r mod loc; do
    [ "$mod" != "$target" ] || continue
    case "$KNOWN" in *" $mod "*) ;; *) continue ;; esac
    case " $direct " in *" $mod "*) continue ;; esac
    err "$loc" "imports-declarados" "'$target' importa '$mod', que não é dependência direta dele. O que fazer: declare '$mod' nas dependências de '$target' em Package.swift se a fronteira permite; senão mova o código para um módulo que já depende de '$mod'."
  done < <(imports "$dir")
done <<<"$TARGETS"

# 2. explicit rules
n=0
while IFS= read -r line || [ -n "$line" ]; do
  n=$((n + 1))
  read -r kind target pat _ <<<"${line%%#*}" || true
  [ -n "$kind" ] || continue
  rule="$kind $target $pat"
  dir="$(field "$target" 2)"
  if [ -z "$pat" ] || [ -z "$dir" ]; then
    err "$RULES:$n" "$rule" "regra inválida: o formato é '<regra> <target> <módulo ou padrão>' e '$target' precisa ser um target (não de teste) do Package.swift. O que fazer: corrija ou remova a linha."
    continue
  fi
  case "$kind" in
    forbid-closure)
      case " $(field "$target" 4) " in *" $pat "*)
        err "$RULES:$n" "$rule" "o fecho de dependências de '$target' contém '$pat'. O que fazer: em Package.swift, tire de '$target' (ou do que ele depende) a dependência que traz '$pat'; se '$target' precisa mesmo desse código, mova-o para um módulo que não dependa de '$pat'."
      esac ;;
    forbid-import)
      while read -r mod loc; do
        # shellcheck disable=SC2254  # $pat is a glob on purpose
        case "$mod" in $pat)
          err "$loc" "$rule" "'$target' não pode importar '$mod'. O que fazer: mova esse código para um módulo onde '$mod' é permitido, ou tire o import."
        esac
      done < <(imports "$dir") ;;
    *)
      err "$RULES:$n" "$rule" "regra desconhecida '$kind'. O que fazer: use forbid-closure ou forbid-import." ;;
  esac
done <"$RULES"

if [ "$errors" -gt 0 ]; then
  echo "check-architecture: $errors violação(ões) de fronteira de módulo" >&2
  exit 1
fi
echo "ok: check-architecture.sh"
