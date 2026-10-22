#!/bin/sh
# Fake figcraft-server for tests. `key` prints the publish address like the real one; otherwise appends
# "<pid> <args>" to $ORQ_FAKE_FIG_LOG and serves GET /healthz on the --listen address.
# ORQ_FAKE_FIG_SERVER_DIE=1 exits 1 s after starting (a crash). ORQ_FAKE_FIG_SERVER_HANG=1 never answers /healthz.
if [ "$1" = key ]; then
  echo "Publish to this address (in FigCraft: File > Publish to server…):"
  echo "  ws://127.0.0.1:47900/?key=fakeKey_123-abc"
  echo "Whoever has it can publish files and manage their links: share it only with people you trust."
  exit 0
fi
[ -n "$ORQ_FAKE_FIG_LOG" ] && echo "$$ $*" >> "$ORQ_FAKE_FIG_LOG"
listen=""
while [ $# -gt 0 ]; do
  [ "$1" = "--listen" ] && listen="$2"
  shift
done
[ "$ORQ_FAKE_FIG_SERVER_HANG" = 1 ] && exec sleep 60
exec /usr/bin/python3 -I -c '
import http.server, os, sys, threading
host, port = sys.argv[1].rsplit(":", 1)
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        ok = self.path == "/healthz"
        self.send_response(200 if ok else 404); self.end_headers()
        if ok: self.wfile.write(b"ok")
    def log_message(self, *a): pass
if os.environ.get("ORQ_FAKE_FIG_SERVER_DIE") == "1":
    threading.Timer(1.0, lambda: os._exit(1)).start()
http.server.HTTPServer((host, int(port)), H).serve_forever()
' "$listen"
