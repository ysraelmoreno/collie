#!/usr/bin/env bash
# Starts Fluxos on 127.0.0.1:${FLUXOS_PORT:-8792}; graph in ${FLUXOS_PADDOCK:-<repo root>}/.collie/flows.
set -euo pipefail
cd "$(dirname "$0")"
command -v python3 >/dev/null 2>&1 || { echo "fluxos: python3 not found (Python 3.9 or newer is needed)" >&2; exit 1; }
export FLUXOS_PADDOCK="${FLUXOS_PADDOCK:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
exec python3 server.py --port "${FLUXOS_PORT:-8792}"
