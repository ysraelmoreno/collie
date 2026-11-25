#!/usr/bin/env bash
# A7: builds the throwaway project the auto-land e2e runs on (docs/superpowers/specs/autoland/a7-validacao-e2e.md).
# usage: scripts/autoland-e2e-fixture.sh <empty-dir-outside-this-repo>
# Creates <dir>/repo (git, 1 commit, a tiny Python project with unittest, collie-work.json with a factory block) and
# <dir>/origin.git (bare remote). It never touches this repository. Prints the two commands the OWNER runs next.
set -euo pipefail
dir="${1:?usage: $0 <empty-dir>}"
here="$(cd "$(dirname "$0")/.." && pwd)"
case "$(cd "$dir" 2>/dev/null && pwd || echo "$dir")" in "$here"|"$here"/*) echo "refuso: o diretório precisa ficar FORA de $here" >&2; exit 2;; esac
mkdir -p "$dir"
[ -z "$(ls -A "$dir")" ] || { echo "refuso: $dir não está vazio" >&2; exit 2; }
repo="$dir/repo"; origin="$dir/origin.git"
git init -q --bare "$origin"
mkdir -p "$repo/tests" "$repo/scripts/ci" "$repo/docs/fabrica/personas"
cd "$repo"
git init -q -b main
git config user.email e2e@example.invalid; git config user.name "Collie e2e"
cat > calc.py <<'PY'
def add(a, b):
    return a + b
PY
: > tests/__init__.py
cat > tests/test_calc.py <<'PY'
import unittest
from calc import add

class CalcTests(unittest.TestCase):
    def test_add(self):
        self.assertEqual(add(1, 2), 3)

if __name__ == "__main__":
    unittest.main()
PY
cat > scripts/gate.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -m unittest discover -s tests -t . -q
SH
cat > scripts/ci/run-tests.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 -m unittest discover -s tests -t . -q
SH
chmod +x scripts/gate.sh scripts/ci/run-tests.sh
for p in correcao testes; do
  src="$here/docs/fabrica/personas/$p.md"; [ -f "$src" ] && cp "$src" "docs/fabrica/personas/$p.md"
done
cat > collie-work.json <<'JSON'
{
  "version": 1,
  "gate": "bash scripts/gate.sh",
  "factory": {
    "version": 1,
    "review": { "personas": ["correcao", "testes"], "threshold": "major", "callOwner": true },
    "guardrails": { "budgetSeconds": 3600, "maxTries": 2, "destructive": ["git push"], "land": "factory-paddock", "autoLandPerDay": 5 }
  }
}
JSON
printf '.collie/\n__pycache__/\n' > .gitignore
git add -A && git commit -qm "e2e fixture: calc with unittest, gate and factory profile"
git remote add origin "file://$origin"
git push -q origin main
echo "pronto: $repo (remoto $origin)"
echo "Como DONO, rode:"
echo "  collie paddock create e2e-fabrica --repo $repo --factory"
echo "  collie factory doctor   # dentro do cercado e2e-fabrica: static e judge >= 1"
