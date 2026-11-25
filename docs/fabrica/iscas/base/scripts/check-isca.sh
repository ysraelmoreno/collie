#!/usr/bin/env bash
# Check da tarefa-isca (U4): criado pela skill factory-bait na cópia descartável, antes do patch. Nunca no repositório real.
set -euo pipefail
cd "$(dirname "$0")/.."
test -f isca/LEIA.md
grep -q "isca" isca/LEIA.md
