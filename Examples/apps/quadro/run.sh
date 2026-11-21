#!/usr/bin/env bash
# Starts the Quadro server on 127.0.0.1:${QUADRO_PORT:-8791}; data in ${QUADRO_DIR:-$HOME/.collie/quadro}.
set -euo pipefail
if ! command -v python3 >/dev/null 2>&1; then
  echo "quadro: python3 not found (Python 3.9 or newer is needed)" >&2
  exit 1
fi
if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)'; then
  echo "quadro: Python 3.9 or newer is needed (found $(python3 -V 2>&1))" >&2
  exit 1
fi
export QUADRO_DIR="${QUADRO_DIR:-$HOME/.collie/quadro}"
exec python3 "$(dirname "$0")/server.py" --port "${QUADRO_PORT:-8791}"
