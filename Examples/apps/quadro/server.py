"""Quadro HTTP server: loopback only, JSON API, live updates over SSE.

Python 3.9, standard library only.

    python3 server.py [--port N] [--dir PATH]

`--port 0` (the default) picks a free port; the real one is printed as
`quadro: http://127.0.0.1:<port>`. The data folder is `--dir`, else
`$QUADRO_DIR`, else `$HOME/.collie/quadro`.

Live updates: writers only bump a version number under a condition
variable (they never wait on a client). Each SSE client runs in its own
thread, wakes on the bump, reads the *current* document and sends it. A
slow client therefore skips intermediate states and gets the latest one;
there is no per-client queue to grow.
"""

import argparse
import json
import os
import signal
import socket
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

from store import Invalid, NotFound, Store, StoreCorrupt, default_dir

HOST = "127.0.0.1"
MAX_BODY = 64 * 1024
STREAM_EVENTS = 20
PING_SECONDS = 15.0

UI_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ui")
UI_FILES = {
    "index.html": "text/html; charset=utf-8",
    "app.js": "text/javascript; charset=utf-8",
    "style.css": "text/css; charset=utf-8",
}
LOOPBACK_NAMES = ("127.0.0.1", "localhost")

GET_ROUTES = ("/api/health", "/api/board", "/api/cards", "/api/card",
              "/api/events", "/api/stream")
POST_ROUTES = ("/api/card/create", "/api/card/update", "/api/card/move",
               "/api/card/comment", "/api/card/archive", "/api/card/restore")


class HttpError(Exception):
    def __init__(self, status, message):
        Exception.__init__(self, message)
        self.status = status
        self.message = message


class Hub(object):
    """Change signal shared by writers and SSE clients."""

    def __init__(self):
        self._cond = threading.Condition()
        self.version = 0
        self.clients = 0
        self.closed = False

    def publish(self):
        with self._cond:
            self.version += 1
            self._cond.notify_all()

    def close(self):
        with self._cond:
            self.closed = True
            self._cond.notify_all()

    def wait_change(self, seen, timeout):
        """Returns (version, closed) once the version moved past `seen`,
        the hub closed, or `timeout` passed."""
        with self._cond:
            self._cond.wait_for(lambda: self.closed or self.version != seen, timeout)
            return self.version, self.closed

    def join(self):
        with self._cond:
            if self.closed:
                return False
            self.clients += 1
            self._cond.notify_all()
            return True

    def leave(self):
        with self._cond:
            self.clients -= 1
            self._cond.notify_all()

    def wait_clients(self, count, timeout):
        """Test helper: wait until exactly `count` SSE clients are attached."""
        with self._cond:
            return self._cond.wait_for(lambda: self.clients == count, timeout)


def _first(query, name):
    values = query.get(name)
    if not values or values[0] == "":
        return None
    return values[0]


def _labels_arg(value):
    """Collie sends a string param as text: "a, b" becomes ["a", "b"]."""
    if isinstance(value, str):
        return [part.strip() for part in value.split(",") if part.strip()]
    return value


def _index_arg(value):
    """Collie sends an int param as a JSON number, possibly 2.0."""
    if isinstance(value, float) and value.is_integer():
        return int(value)
    return value


def _split_host(value):
    """'name:port' or '[v6]:port' -> (name, port or None)."""
    value = value.strip().lower()
    if value.startswith("["):
        end = value.find("]")
        if end < 0:
            return value, None
        name, rest = value[1:end], value[end + 1:]
        return name, rest[1:] if rest.startswith(":") else None
    if value.count(":") == 1:
        name, port = value.split(":")
        return name, port
    return value, None


class Handler(BaseHTTPRequestHandler):
    server_version = "quadro"
    sys_version = ""
    protocol_version = "HTTP/1.0"
    timeout = 30   # a socket that stalls (a short body, a client that never reads) frees its thread

    # ---- plumbing ------------------------------------------------------

    def log_message(self, format, *args):
        if self.server.verbose:
            BaseHTTPRequestHandler.log_message(self, format, *args)

    def _send(self, status, body, content_type="application/json; charset=utf-8",
              extra=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def _json(self, status, value):
        self._send(status, json.dumps(value, ensure_ascii=False).encode("utf-8"))

    def _error(self, status, message):
        self.close_connection = True
        try:
            self._json(status, {"error": message})
        except OSError:
            pass

    def _check_origin(self):
        port = str(self.server.server_address[1])
        host = self.headers.get("Host")
        if not host:
            raise HttpError(400, "missing Host header")
        name, given = _split_host(host)
        if name not in LOOPBACK_NAMES or (given is not None and given != port):
            raise HttpError(403, "host not allowed")
        origin = self.headers.get("Origin")
        if origin is not None:
            allowed = ["http://%s:%s" % (n, port) for n in LOOPBACK_NAMES]
            if origin.strip().lower().rstrip("/") not in allowed:
                raise HttpError(403, "origin not allowed")

    def _dispatch(self, method):
        try:
            self._check_origin()
            parts = urlsplit(self.path)
            path = parts.path
            query = parse_qs(parts.query, keep_blank_values=True)
            if method == "GET" and path in GET_ROUTES:
                return self._get(path, query)
            if method == "POST" and path in POST_ROUTES:
                return self._post(path)
            if path in GET_ROUTES or path in POST_ROUTES:
                raise HttpError(405, "method not allowed")
            if method == "GET":
                return self._static(path)
            if self._static_name(path) is not None:
                raise HttpError(405, "method not allowed")
            raise HttpError(404, "not found")
        except HttpError as exc:
            self._error(exc.status, exc.message)
        except Invalid as exc:
            self._error(400, str(exc) or "invalid request")
        except NotFound as exc:
            self._error(404, str(exc) or "not found")
        except StoreCorrupt:
            self._error(500, "board data is unreadable")
        except (BrokenPipeError, ConnectionResetError, socket.timeout):
            self.close_connection = True
        except Exception:
            self._error(500, "internal error")

    def do_GET(self):
        self._dispatch("GET")

    def do_POST(self):
        self._dispatch("POST")

    def do_PUT(self):
        self._dispatch("PUT")

    def do_DELETE(self):
        self._dispatch("DELETE")

    def do_PATCH(self):
        self._dispatch("PATCH")

    def do_HEAD(self):
        self._dispatch("HEAD")

    def do_OPTIONS(self):
        self._dispatch("OPTIONS")

    # ---- static files --------------------------------------------------

    @staticmethod
    def _static_name(path):
        if path in ("/", "/ui", "/ui/"):
            return "index.html"
        for prefix in ("/ui/", "/"):
            if path.startswith(prefix) and path[len(prefix):] in UI_FILES:
                return path[len(prefix):]
        return None

    def _static(self, path):
        name = self._static_name(path)
        if name is None:
            raise HttpError(404, "not found")
        try:
            with open(os.path.join(UI_DIR, name), "rb") as handle:
                body = handle.read()
        except OSError:
            raise HttpError(404, "not found")
        self._send(200, body, UI_FILES[name])

    # ---- reads ---------------------------------------------------------

    def _get(self, path, query):
        store = self.server.store
        if path == "/api/health":
            return self._json(200, {"ok": True, "revision": store.revision})
        if path == "/api/board":
            return self._json(200, store.board(include_archived=_first(query, "archived") in ("1", "true")))
        if path == "/api/cards":
            return self._json(200, {"cards": store.cards(
                column=_first(query, "column"), label=_first(query, "label"),
                assignee=_first(query, "assignee"), q=_first(query, "q"))})
        if path == "/api/card":
            return self._json(200, store.card(_first(query, "id") or ""))
        if path == "/api/events":
            raw = _first(query, "since") or "0"
            if not raw.isdigit():
                raise HttpError(400, "since must be a non-negative integer")
            return self._json(200, {"events": store.events(since=int(raw)),
                                    "revision": store.revision})
        return self._stream()

    # ---- writes --------------------------------------------------------

    def _read_json(self):
        ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
        if ctype != "application/json":
            raise HttpError(415, "Content-Type must be application/json")
        if self.headers.get("Transfer-Encoding"):
            raise HttpError(400, "send a Content-Length body")
        raw = self.headers.get("Content-Length")
        if raw is None or not raw.strip().isdigit():
            raise HttpError(400, "Content-Length required")
        length = int(raw)
        if length > MAX_BODY:
            if length <= 16 * MAX_BODY:
                self.rfile.read(length)  # drain so the client reads the 413
            raise HttpError(413, "body too large (max %d bytes)" % MAX_BODY)
        data = self.rfile.read(length)
        try:
            body = json.loads(data.decode("utf-8")) if data else None
        except (UnicodeDecodeError, ValueError):
            raise HttpError(400, "body is not valid JSON")
        if not isinstance(body, dict):
            raise HttpError(400, "body must be a JSON object")
        return body

    def _post(self, path):
        body = self._read_json()
        store = self.server.store
        card_id = body.get("id")
        by = body.get("by", "")
        if path == "/api/card/create":
            if "title" not in body:
                raise HttpError(400, "title is required")
            card = store.create_card(body["title"], body=body.get("body", ""),
                                     column=body.get("column", "todo"),
                                     labels=_labels_arg(body.get("labels", ())),
                                     assignee=body.get("assignee", ""), by=by)
            status = 201
        elif path == "/api/card/update":
            fields = {k: body[k] for k in ("title", "body", "labels", "assignee") if k in body}
            if "labels" in fields:
                fields["labels"] = _labels_arg(fields["labels"])
            card = store.update_card(card_id, by=by, **fields)
            status = 200
        elif path == "/api/card/move":
            if "column" not in body:
                raise HttpError(400, "column is required")
            card = store.move_card(card_id, body["column"], index=_index_arg(body.get("index")), by=by)
            status = 200
        elif path == "/api/card/comment":
            if "text" not in body:
                raise HttpError(400, "text is required")
            card = store.comment(card_id, body["text"], by=by)
            status = 200
        elif path == "/api/card/archive":
            card = store.archive(card_id, by=by)
            status = 200
        else:
            card = store.restore(card_id, by=by)
            status = 200
        self.server.hub.publish()
        self._json(status, card)

    # ---- live stream ---------------------------------------------------

    def _snapshot(self):
        store = self.server.store
        doc = store.board()
        doc["events"] = store.events(since=max(0, doc["revision"] - STREAM_EVENTS),
                                     limit=STREAM_EVENTS)
        return doc

    def _stream(self):
        hub = self.server.hub
        if not hub.join():
            raise HttpError(500, "server is shutting down")
        self.close_connection = True
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            seen = hub.version
            doc = self._snapshot()
            sent = doc["revision"]
            self._event(doc)
            while True:
                version, closed = hub.wait_change(seen, self.server.ping)
                if closed:
                    break
                if version != seen:
                    seen = version
                    doc = self._snapshot()
                    sent = doc["revision"]
                    self._event(doc)
                    continue
                # Quiet interval: catch writes made by another process.
                if self.server.store.revision != sent:
                    doc = self._snapshot()
                    sent = doc["revision"]
                    self._event(doc)
                else:
                    self.wfile.write(b": ping\n\n")
        except (OSError, ValueError):
            pass
        except (Invalid, NotFound, StoreCorrupt):
            pass
        finally:
            hub.leave()

    def _event(self, doc):
        data = json.dumps(doc, ensure_ascii=False, separators=(",", ":"))
        self.wfile.write(("event: document\ndata: %s\n\n" % data).encode("utf-8"))


class QuadroServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, store, port=0, ping=PING_SECONDS, verbose=False):
        if not ping or ping <= 0:
            raise ValueError("ping must be positive")
        self.store = store
        self.ping = float(ping)
        self.verbose = verbose
        self.hub = Hub()
        ThreadingHTTPServer.__init__(self, (HOST, port), Handler)

    @property
    def port(self):
        return self.server_address[1]

    @property
    def url(self):
        return "http://%s:%d" % (HOST, self.port)

    def shutdown(self):
        """Stops serve_forever and ends every SSE stream."""
        self.hub.close()
        ThreadingHTTPServer.shutdown(self)

    def server_close(self):
        self.hub.close()
        ThreadingHTTPServer.server_close(self)

    def handle_error(self, request, client_address):
        if self.verbose:
            ThreadingHTTPServer.handle_error(self, request, client_address)


def serve(store, port=0, ping=PING_SECONDS, verbose=False):
    """A bound, not yet running server: call serve_forever() (in a thread
    for tests), then shutdown() and server_close()."""
    return QuadroServer(store, port=port, ping=ping, verbose=verbose)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Quadro: local kanban server")
    parser.add_argument("--port", type=int, default=0, help="port (0 = any free port)")
    parser.add_argument("--dir", default=None, help="data folder (default: $QUADRO_DIR)")
    parser.add_argument("--ping", type=float, default=PING_SECONDS, help=argparse.SUPPRESS)
    parser.add_argument("--verbose", action="store_true", help="log requests to stderr")
    args = parser.parse_args(argv)
    if args.port < 0 or args.port > 65535:
        parser.error("port must be 0..65535")
    store = Store(args.dir or default_dir())
    server = serve(store, port=args.port, ping=args.ping, verbose=args.verbose)
    print("quadro: %s" % server.url, flush=True)

    def stop(signum, frame):
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.hub.close()
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
