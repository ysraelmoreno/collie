#!/usr/bin/env bash
# U2: scripts/factory-detect.sh against scripts/fixtures/factory-detect/<stack>/ (one folder per stack), an empty folder,
# valid JSON every time, and a tree that is the same before and after (the detector only reads).
set -euo pipefail
cd "$(dirname "$0")/.."
fx=scripts/fixtures/factory-detect
fail=0
tree() { (cd "$1" && find . -print | LC_ALL=C sort && find . -type f -exec shasum {} \; | LC_ALL=C sort); }
# field <json> <python expression over d>
field() { printf '%s' "$1" | python3 -I -c "import json,sys; d=json.load(sys.stdin); print(($2))"; }

check() {   # check <dir> <expected stack> <expected testRunner or None>
  local dir=$1 want=$2 runner=$3 before after out
  before=$(tree "$dir")
  out=$(scripts/factory-detect.sh "$dir") || { echo "FAIL $dir: detector saiu com erro"; fail=1; return; }
  after=$(tree "$dir")
  [ "$before" = "$after" ] || { echo "FAIL $dir: o detector mudou a árvore"; fail=1; }
  field "$out" 1 >/dev/null 2>&1 || { echo "FAIL $dir: JSON inválido"; fail=1; return; }
  local got gotr
  got=$(field "$out" "d['stack']"); gotr=$(field "$out" "d['testRunner']")
  [ "$got" = "$want" ] || { echo "FAIL $dir: stack '$got', esperava '$want'"; fail=1; }
  [ "$gotr" = "$runner" ] || { echo "FAIL $dir: testRunner '$gotr', esperava '$runner'"; fail=1; }
  [ "$(field "$out" "sorted(d) == sorted(['stack','stacks','testRunner','linter','formatter','tools','ci','existing'])")" = True ] \
    || { echo "FAIL $dir: chaves do JSON"; fail=1; }
  echo "ok $dir -> $got"
}

check $fx/swift swift "swift test"
check $fx/node node "npx vitest run"
check $fx/python python pytest
check $fx/kotlin kotlin "gradle test"
check $fx/flutter flutter "flutter test"
check $fx/rust rust "cargo test"
check $fx/go go "go test ./..."

# the extra signals the fixtures carry
s=$(scripts/factory-detect.sh $fx/swift)
[ "$(field "$s" "d['linter'], d['ci']")" = "('swiftlint', ['.github/workflows/ci.yml'])" ] || { echo "FAIL swift: linter/ci"; fail=1; }
n=$(scripts/factory-detect.sh $fx/node)
[ "$(field "$n" "d['linter'], d['tools']['node']['typecheck']")" = "('eslint', 'tsc --noEmit')" ] || { echo "FAIL node: eslint/tsc"; fail=1; }
y=$(scripts/factory-detect.sh $fx/python)
[ "$(field "$y" "d['linter'], d['formatter']")" = "('ruff check', 'ruff format')" ] || { echo "FAIL python: ruff"; fail=1; }
[ "$(field "$(scripts/factory-detect.sh $fx/rust)" "d['ci']")" = "['Makefile']" ] || { echo "FAIL rust: Makefile no ci"; fail=1; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
check "$tmp" unknown None
[ "$(field "$(scripts/factory-detect.sh "$tmp")" "d['stacks'], d['existing']")" \
  = "([], {'checkScripts': [], 'collieWork': False, 'personas': False})" ] || { echo "FAIL vazio: stacks/existing"; fail=1; }

# several stacks and what already exists
cp $fx/swift/Package.swift $fx/node/package.json "$tmp"/
mkdir -p "$tmp/scripts" "$tmp/docs/fabrica/personas"
echo '{}' > "$tmp/collie-work.json"; echo 'swift test' > "$tmp/scripts/check-a.sh"
m=$(scripts/factory-detect.sh "$tmp")
[ "$(field "$m" "d['stack'], d['stacks'], d['existing']")" \
  = "('swift', ['swift', 'node'], {'checkScripts': ['scripts/check-a.sh'], 'collieWork': True, 'personas': True})" ] \
  || { echo "FAIL várias stacks/existing: $m"; fail=1; }

scripts/factory-detect.sh "$tmp/nao-existe" >/dev/null 2>&1 && { echo "FAIL: diretório ausente devia falhar"; fail=1; }
[ $fail = 0 ] && echo "test-factory-detect: tudo ok"
exit $fail
