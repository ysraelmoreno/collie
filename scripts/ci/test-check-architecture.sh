#!/bin/bash
# Check of scripts/ci/check-architecture.sh against a fabricated package (JSON + source tree), then the real repo.
# Run: scripts/ci/test-check-architecture.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
C="$PWD/scripts/ci/check-architecture.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Fabricated graph: app → Mid → Base, and Mid → product Ext.
cat >"$T/pkg.json" <<'JSON'
{"targets": [
  {"name": "Base", "type": "regular", "dependencies": []},
  {"name": "Mid", "type": "regular", "dependencies": [{"byName": ["Base", null]}, {"product": ["Ext", "Ext", null, null]}]},
  {"name": "app", "type": "executable", "dependencies": [{"byName": ["Mid", null]}]},
  {"name": "MidTests", "type": "test", "dependencies": [{"byName": ["Mid", null]}]}
]}
JSON
reset() { # clean tree, every import declared, no rules
  rm -rf "$T/Sources" "$T/Tests" "$T/scripts"
  mkdir -p "$T/Sources/Base" "$T/Sources/Mid/Sub" "$T/Sources/app" "$T/Tests/MidTests" "$T/scripts/ci"
  printf 'import Foundation\n' >"$T/Sources/Base/a.swift"
  printf 'import Foundation\n@preconcurrency import Base\n// import app\n' >"$T/Sources/Mid/m.swift"
  printf 'public import struct Ext.Thing\n' >"$T/Sources/Mid/Sub/n.swift"
  printf 'import Mid\n' >"$T/Sources/app/main.swift"
  printf '@testable import Mid\nimport Base\n' >"$T/Tests/MidTests/t.swift" # Tests/ is out of scope
  printf '# no rules\n' >"$T/scripts/ci/architecture-rules.txt"
}
run() { ARCH_ROOT="$T" "$C" --package-json "$T/pkg.json" 2>&1; }
passes() { out="$(run)" || fail "$1: falhou ($out)"; }
fails() { # <case> <substring>…: must fail and mention every substring
  local name="$1"; shift
  if out="$(run)"; then fail "$name: passou"; fi
  for want in "$@"; do [[ "$out" == *"$want"* ]] || fail "$name: sem '$want' ($out)"; done
}

# declared imports pass (attributes, access modifiers, `import struct`, comments, Tests/ ignored)
reset; passes "declarado"

# transitive import fails: target Base and product Ext reach app only through Mid
reset; printf 'import Mid\nimport Base\n  import Ext\n' >"$T/Sources/app/main.swift"
fails "transitivo" "Sources/app/main.swift:2: [imports-declarados]" "Sources/app/main.swift:3: [imports-declarados]" \
  "O que fazer:" "2 violação"

# forbid-closure: violated through a transitive dependency; fine when the module is not in the closure
reset; printf '# c\n\nforbid-closure app Ext # trailing\n' >"$T/scripts/ci/architecture-rules.txt"
fails "forbid-closure" "scripts/ci/architecture-rules.txt:3: [forbid-closure app Ext]" "O que fazer:"
reset; printf 'forbid-closure Base Ext\nforbid-closure Base Mid\n' >"$T/scripts/ci/architecture-rules.txt"
passes "forbid-closure fora do fecho"

# forbid-import: glob over any module, Apple frameworks included; fine when nothing matches
reset; printf 'forbid-import Base Found*\n' >"$T/scripts/ci/architecture-rules.txt"
fails "forbid-import" "Sources/Base/a.swift:1: [forbid-import Base Found*]" "O que fazer:"
reset; printf 'forbid-import Base AppKit\nforbid-import Mid app\n' >"$T/scripts/ci/architecture-rules.txt"
passes "forbid-import sem casar"

# a typo in the rules file is an error, not a silently skipped rule
reset; printf 'forbid-closure Nope Ext\n' >"$T/scripts/ci/architecture-rules.txt"
fails "target desconhecido" "architecture-rules.txt:1:" "regra inválida"
reset; printf 'forbid-everything app Ext\n' >"$T/scripts/ci/architecture-rules.txt"
fails "regra desconhecida" "architecture-rules.txt:1:" "regra desconhecida"

# the real repo passes with the real rules
swift package dump-package >"$T/real.json"
out="$("$C" --package-json "$T/real.json" 2>&1)" || fail "repo real: falhou ($out)"

# PRD measure: `import SwiftTerm` in Sources/collie/ fails, on the real graph with the real rules
reset; cp scripts/ci/architecture-rules.txt "$T/scripts/ci/"; cp "$T/real.json" "$T/pkg.json"
mkdir -p "$T/Sources/collie"; printf 'import SwiftTerm\n' >"$T/Sources/collie/x.swift"
fails "SwiftTerm no collie" "Sources/collie/x.swift:1: [imports-declarados]" "'collie' importa 'SwiftTerm'"

echo "ok: check-architecture.sh"
