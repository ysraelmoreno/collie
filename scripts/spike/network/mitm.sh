#!/bin/sh
# Spike proxy: mitmdump on 127.0.0.1:${PORT:-8899}, confdir isolated next to this script (CA generated there,
# never added to the Mac trust store). HTTP/2 off so clients negotiate http/1.1 (the MVP plan).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
exec /opt/homebrew/bin/mitmdump --listen-host 127.0.0.1 --listen-port "${PORT:-8899}" \
  --set confdir="$here/.mitm" --set http2="${HTTP2:-false}" -q -s "$here/flows.py"
