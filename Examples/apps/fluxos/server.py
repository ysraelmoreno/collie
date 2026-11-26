"""Fluxos server (d9): the agent's commands over the paddock's app graph, on loopback only.

GET  /healthz                     -> {"ok": true}
GET  /api/goals                   -> {"goals": {name: sig}}
GET  /api/go?goal=<meta>[&from=]  -> {"plan": FlowPlan} or 404 {"error": reason}; never runs anything
GET  /api/show?goal=<meta>        -> the goal's node with the live edges in and out of it
POST /api/learn                   -> rebuilds graph.json from actions.jsonl

The graph lives in `<paddock>/.collie/flows/` (store.py). Nothing here talks to the device or to the daemon: the agent
runs the plan with `collie device run --plan`. Python 3.9 stdlib only.
"""

import argparse
import json
import os
import signal
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import planner  # noqa: E402
from store import Invalid, Store  # noqa: E402

HOST = "127.0.0.1"
LOOPBACK_NAMES = ("127.0.0.1", "localhost")


def last_sig(store):
    """The screen the last logged action ended on, or "" (the default start of `go`)."""
    try:
        with open(os.path.join(store.dir, "actions.jsonl"), encoding="utf-8", errors="replace") as handle:
            lines = handle.read().splitlines()
    except FileNotFoundError:
        return ""
    for raw in reversed(lines):
        try:
            sig = json.loads(raw).get("sigAfter")
        except (ValueError, AttributeError):
            continue
        if isinstance(sig, str) and sig:
            return sig
    return ""


class Handler(BaseHTTPRequestHandler):
    server_version = "fluxos"
    sys_version = ""
    protocol_version = "HTTP/1.0"
    timeout = 30

    def log_message(self, format, *args):
        pass

    def _json(self, status, value):
        body = json.dumps(value, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _loopback(self):
        host = (self.headers.get("Host") or "").rsplit(":", 1)[0].strip("[]").lower()
        origin = self.headers.get("Origin")
        if host not in LOOPBACK_NAMES:
            return False
        if origin is not None:
            allowed = ["http://%s:%d" % (n, self.server.server_address[1]) for n in LOOPBACK_NAMES]
            return origin.strip().lower().rstrip("/") in allowed
        return True

    def _dispatch(self, method):
        if not self._loopback():
            return self._json(403, {"error": "host not allowed"})
        parts = urlsplit(self.path)
        q = {k: v[0] for k, v in parse_qs(parts.query).items()}
        store = self.server.store
        try:
            if method == "GET" and parts.path == "/healthz":
                return self._json(200, {"ok": True})
            if method == "GET" and parts.path == "/api/goals":
                return self._json(200, {"goals": store.goals()})
            if method == "GET" and parts.path == "/api/go":
                goal = q.get("goal", "").strip()
                if not goal:
                    return self._json(400, {"error": "falta a meta"})
                start = q.get("from", "").strip() or last_sig(store)
                plan, reason = planner.plan(store.load(), start, goal)
                if plan is None:
                    return self._json(404, {"error": reason})
                return self._json(200, {"goal": goal, "from": start, "plan": plan})
            if method == "GET" and parts.path == "/api/show":
                goal = q.get("goal", "").strip()
                graph = store.load()
                sig = planner.resolve(graph, goal)
                if not goal or sig not in (graph.get("nodes") or []):
                    return self._json(404, {"error": "meta desconhecida: %s" % goal})
                live = [e for e in graph.get("edges") or [] if not e.get("obsolete")]
                return self._json(200, {"goal": goal, "sig": sig,
                                        "in": [e for e in live if e["to"] == sig],
                                        "out": [e for e in live if e["from"] == sig]})
            if method == "POST" and parts.path == "/api/learn":
                g = store.learn()
                return self._json(200, {"nodes": len(g["nodes"]), "edges": len(g["edges"]), "skipped": g["skipped"],
                                        "goals": g["goals"]})
            return self._json(404, {"error": "not found"})
        except Invalid as exc:
            return self._json(400, {"error": str(exc)})
        except (ValueError, KeyError, TypeError):
            return self._json(500, {"error": "graph.json ilegível; rode learn"})

    def do_GET(self):
        self._dispatch("GET")

    def do_POST(self):
        self._dispatch("POST")


class FluxosServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, store, port=0):
        self.store = store
        ThreadingHTTPServer.__init__(self, (HOST, port), Handler)

    @property
    def url(self):
        return "http://%s:%d" % (HOST, self.server_address[1])


def main(argv=None):
    parser = argparse.ArgumentParser(description="Fluxos: app graph and flow planner")
    parser.add_argument("--port", type=int, default=8792)
    parser.add_argument("--paddock", default=os.environ.get("FLUXOS_PADDOCK") or os.getcwd())
    args = parser.parse_args(argv)
    server = FluxosServer(Store(args.paddock), port=args.port)
    print("fluxos: %s" % server.url, flush=True)
    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=server.shutdown, daemon=True).start())
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
