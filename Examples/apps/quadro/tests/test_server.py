import http.client
import json
import os
import queue
import shutil
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import server  # noqa: E402
from store import Store  # noqa: E402

WAIT = 10.0


class Running(object):
    """A server on an ephemeral port, serving in a background thread."""

    def __init__(self, data_dir, ping=15.0):
        self.store = Store(data_dir)
        self.httpd = server.serve(self.store, port=0, ping=ping)
        self.port = self.httpd.port
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def stop(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(WAIT)


class SSEReader(object):
    """Reads an SSE stream in a thread; each message lands in `self.items`
    as ("document", dict), ("comment", text) or ("eof", None)."""

    def __init__(self, port, headers=None):
        self.conn = http.client.HTTPConnection("127.0.0.1", port, timeout=WAIT)
        self.conn.request("GET", "/api/stream", headers=headers or {})
        self.response = self.conn.getresponse()
        self.items = queue.Queue()
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self):
        event, data = None, []
        try:
            while True:
                line = self.response.readline()
                if not line:
                    break
                line = line.decode("utf-8").rstrip("\n")
                if line == "":
                    if event == "document":
                        self.items.put(("document", json.loads("\n".join(data))))
                    event, data = None, []
                elif line.startswith(":"):
                    self.items.put(("comment", line[1:].strip()))
                elif line.startswith("event:"):
                    event = line[6:].strip()
                elif line.startswith("data:"):
                    data.append(line[5:].lstrip())
        except (OSError, ValueError):
            pass
        self.items.put(("eof", None))

    def next(self, kind):
        while True:
            got, value = self.items.get(timeout=WAIT)
            if got == kind:
                return value
            if got == "eof":
                raise AssertionError("stream ended while waiting for %s" % kind)

    def document_where(self, predicate):
        while True:
            doc = self.next("document")
            if predicate(doc):
                return doc

    def close(self):
        try:
            self.response.close()
        finally:
            self.conn.close()


class ServerTestCase(unittest.TestCase):
    ping = 15.0

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="quadro-server-")
        self.data_dir = os.path.join(self.tmp, "data")
        self.srv = Running(self.data_dir, ping=self.ping)
        self.readers = []

    def tearDown(self):
        for reader in self.readers:
            reader.close()
        self.srv.stop()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def stream(self, **kw):
        reader = SSEReader(self.srv.port, **kw)
        self.readers.append(reader)
        return reader

    def call(self, method, path, body=None, headers=None, raw=None, port=None):
        conn = http.client.HTTPConnection("127.0.0.1", port or self.srv.port, timeout=WAIT)
        try:
            hdrs = dict(headers or {})
            data = raw
            if body is not None:
                data = json.dumps(body).encode("utf-8")
                hdrs.setdefault("Content-Type", "application/json")
            conn.request(method, path, body=data, headers=hdrs)
            resp = conn.getresponse()
            payload = resp.read()
            ctype = resp.getheader("Content-Type") or ""
            value = json.loads(payload.decode("utf-8")) if ctype.startswith("application/json") \
                else payload
            return resp.status, value, resp
        finally:
            conn.close()

    def ok(self, method, path, body=None, status=200):
        got, value, _ = self.call(method, path, body)
        self.assertEqual(got, status, value)
        return value

    def create(self, title="tarefa", **extra):
        body = {"title": title}
        body.update(extra)
        return self.ok("POST", "/api/card/create", body, status=201)

    def assertError(self, result, status):
        got, value, resp = result
        self.assertEqual(got, status, value)
        self.assertIsInstance(value, dict)
        self.assertEqual(sorted(value), ["error"])
        self.assertIsNone(resp.getheader("Access-Control-Allow-Origin"))
        return value["error"]


class RouteTests(ServerTestCase):
    def test_health(self):
        self.assertEqual(self.ok("GET", "/api/health"), {"ok": True, "revision": 0})
        self.create()
        self.assertEqual(self.ok("GET", "/api/health")["revision"], 1)

    def test_board_and_archived(self):
        a = self.create("a")
        self.create("b")
        self.ok("POST", "/api/card/archive", {"id": a["id"]})
        board = self.ok("GET", "/api/board")
        self.assertEqual([c["title"] for c in board["cards"]], ["b"])
        self.assertEqual([c["id"] for c in board["columns"]], ["todo", "doing", "review", "done"])
        full = self.ok("GET", "/api/board?archived=1")
        self.assertEqual(sorted(c["title"] for c in full["cards"]), ["a", "b"])

    def test_cards_filters(self):
        self.create("alpha", labels=["bug"], assignee="ana")
        self.create("beta", column="doing")
        self.assertEqual(len(self.ok("GET", "/api/cards")["cards"]), 2)
        self.assertEqual([c["title"] for c in self.ok("GET", "/api/cards?column=doing")["cards"]],
                         ["beta"])
        self.assertEqual([c["title"] for c in self.ok("GET", "/api/cards?label=bug")["cards"]],
                         ["alpha"])
        self.assertEqual([c["title"] for c in self.ok("GET", "/api/cards?assignee=ana")["cards"]],
                         ["alpha"])
        self.assertEqual([c["title"] for c in self.ok("GET", "/api/cards?q=BET")["cards"]],
                         ["beta"])
        self.assertEqual(self.ok("GET", "/api/cards?column=&q=")["cards"].__len__(), 2)

    def test_card(self):
        card = self.create("x")
        self.assertEqual(self.ok("GET", "/api/card?id=" + card["id"])["title"], "x")
        self.assertError(self.call("GET", "/api/card?id=ffffffff"), 404)
        self.assertError(self.call("GET", "/api/card"), 400)

    def test_create(self):
        card = self.create("novo", body="corpo", column="review", labels=["a"],
                           assignee="bia", by="agente-1")
        self.assertEqual(card["column"], "review")
        self.assertEqual(card["createdBy"], "agente-1")
        self.assertEqual(len(card["id"]), 8)
        self.assertError(self.call("POST", "/api/card/create", {}), 400)
        self.assertError(self.call("POST", "/api/card/create", {"title": ""}), 400)
        self.assertError(self.call("POST", "/api/card/create", {"title": "t", "column": "x"}), 400)
        self.assertError(self.call("POST", "/api/card/create", {"title": "t" * 201}), 400)
        self.assertError(self.call("POST", "/api/card/create", {"title": "t", "labels": "a"}), 400)

    def test_update(self):
        card = self.create("old")
        got = self.ok("POST", "/api/card/update", {"id": card["id"], "title": "new", "body": "b"})
        self.assertEqual((got["title"], got["body"]), ("new", "b"))
        self.assertError(self.call("POST", "/api/card/update", {"id": "ffffffff", "title": "x"}), 404)
        self.assertError(self.call("POST", "/api/card/update", {"id": card["id"], "title": ""}), 400)
        self.assertError(self.call("POST", "/api/card/update", {"title": "x"}), 400)

    def test_move(self):
        a = self.create("a")
        b = self.create("b")
        self.ok("POST", "/api/card/move", {"id": b["id"], "column": "todo", "index": 0})
        self.assertEqual([c["title"] for c in self.ok("GET", "/api/cards?column=todo")["cards"]],
                         ["b", "a"])
        moved = self.ok("POST", "/api/card/move", {"id": a["id"], "column": "done"})
        self.assertEqual(moved["column"], "done")
        self.assertError(self.call("POST", "/api/card/move", {"id": a["id"]}), 400)
        self.assertError(self.call("POST", "/api/card/move", {"id": a["id"], "column": "x"}), 400)
        self.assertError(self.call("POST", "/api/card/move",
                                   {"id": a["id"], "column": "todo", "index": -1}), 400)
        self.assertError(self.call("POST", "/api/card/move",
                                   {"id": "ffffffff", "column": "todo"}), 404)

    def test_comment(self):
        card = self.create()
        got = self.ok("POST", "/api/card/comment", {"id": card["id"], "text": "oi", "by": "ag"})
        self.assertEqual([(c["by"], c["text"]) for c in got["comments"]], [("ag", "oi")])
        self.assertError(self.call("POST", "/api/card/comment", {"id": card["id"]}), 400)
        self.assertError(self.call("POST", "/api/card/comment", {"id": card["id"], "text": ""}), 400)
        self.assertError(self.call("POST", "/api/card/comment", {"id": "ffffffff", "text": "x"}), 404)

    def test_archive_restore(self):
        card = self.create()
        self.assertTrue(self.ok("POST", "/api/card/archive", {"id": card["id"]})["archived"])
        self.assertTrue(self.ok("POST", "/api/card/archive", {"id": card["id"]})["archived"])
        self.assertFalse(self.ok("POST", "/api/card/restore", {"id": card["id"]})["archived"])
        self.assertError(self.call("POST", "/api/card/archive", {"id": "ffffffff"}), 404)
        self.assertError(self.call("POST", "/api/card/restore", {"id": "ffffffff"}), 404)

    def test_events(self):
        card = self.create()
        self.ok("POST", "/api/card/comment", {"id": card["id"], "text": "x"})
        got = self.ok("GET", "/api/events")
        self.assertEqual(got["revision"], 2)
        self.assertEqual([e["type"] for e in got["events"]], ["card.create", "card.comment"])
        self.assertEqual([e["seq"] for e in self.ok("GET", "/api/events?since=1")["events"]], [2])
        self.assertError(self.call("GET", "/api/events?since=-1"), 400)
        self.assertError(self.call("GET", "/api/events?since=abc"), 400)

    def test_static(self):
        status, body, resp = self.call("GET", "/")
        self.assertEqual(status, 200)
        self.assertTrue(resp.getheader("Content-Type").startswith("text/html"))
        self.assertIn(b"<html", body.lower())
        for path, ctype in (("/ui/index.html", "text/html"), ("/ui/app.js", "text/javascript"),
                            ("/ui/style.css", "text/css"), ("/app.js", "text/javascript"),
                            ("/style.css", "text/css")):
            status, _, resp = self.call("GET", path)
            self.assertEqual(status, 200, path)
            self.assertTrue(resp.getheader("Content-Type").startswith(ctype), path)

    def test_static_traversal_and_unknown(self):
        for path in ("/ui/../store.py", "/ui/%2e%2e/store.py", "/ui/..%2fstore.py",
                     "/store.py", "/ui/store.py", "/ui/", "/nope", "/api/nope"):
            if path == "/ui/":
                self.assertEqual(self.call("GET", path)[0], 200)
                continue
            self.assertError(self.call("GET", path), 404)


class SecurityTests(ServerTestCase):
    def test_bad_host(self):
        msg = self.assertError(self.call("GET", "/api/health", headers={"Host": "evil.example"}), 403)
        self.assertNotIn("evil", msg)
        self.assertError(self.call("GET", "/api/health",
                                   headers={"Host": "127.0.0.1:%d" % (self.srv.port + 1)}), 403)
        self.assertError(self.call("POST", "/api/card/create", {"title": "x"},
                                   headers={"Host": "evil.example"}), 403)
        self.assertEqual(self.ok("GET", "/api/health")["revision"], 0)

    def test_good_hosts(self):
        for host in ("127.0.0.1:%d" % self.srv.port, "localhost:%d" % self.srv.port, "localhost"):
            self.assertEqual(self.call("GET", "/api/health", headers={"Host": host})[0], 200, host)

    def test_origin(self):
        self.assertError(self.call("POST", "/api/card/create", {"title": "x"},
                                   headers={"Origin": "http://evil.example"}), 403)
        self.assertError(self.call("GET", "/api/board",
                                   headers={"Origin": "http://evil.example"}), 403)
        self.assertError(self.call("GET", "/api/board", headers={"Origin": "null"}), 403)
        good = "http://127.0.0.1:%d" % self.srv.port
        status, _, resp = self.call("POST", "/api/card/create", {"title": "x"},
                                    headers={"Origin": good})
        self.assertEqual(status, 201)
        self.assertIsNone(resp.getheader("Access-Control-Allow-Origin"))
        self.assertEqual(self.ok("GET", "/api/health")["revision"], 1)

    def test_content_type(self):
        self.assertError(self.call("POST", "/api/card/create", raw=b'{"title": "x"}',
                                   headers={"Content-Type": "text/plain"}), 415)
        self.assertError(self.call("POST", "/api/card/create", raw=b'{"title": "x"}'), 415)
        status, _, _ = self.call("POST", "/api/card/create", raw=b'{"title": "x"}',
                                 headers={"Content-Type": "application/json; charset=utf-8"})
        self.assertEqual(status, 201)

    def test_body_too_large(self):
        big = json.dumps({"title": "x", "body": "a" * (65 * 1024)}).encode("utf-8")
        self.assertError(self.call("POST", "/api/card/create", raw=big,
                                   headers={"Content-Type": "application/json"}), 413)
        self.assertEqual(self.ok("GET", "/api/health")["revision"], 0)

    def test_invalid_json(self):
        for raw in (b"{nope", b"[1, 2]", b"", b"\xff\xfe"):
            self.assertError(self.call("POST", "/api/card/create", raw=raw,
                                       headers={"Content-Type": "application/json"}), 400)

    def test_wrong_method(self):
        self.assertError(self.call("GET", "/api/card/create"), 405)
        self.assertError(self.call("POST", "/api/board", {"x": 1}), 405)
        self.assertError(self.call("PUT", "/api/board", {"x": 1}), 405)
        self.assertError(self.call("DELETE", "/api/card"), 405)
        self.assertError(self.call("POST", "/ui/app.js", {"x": 1}), 405)

    def test_errors_hide_paths_and_traces(self):
        bodies = []
        for result in (self.call("GET", "/api/card?id=ffffffff"),
                       self.call("POST", "/api/card/create", raw=b"{nope",
                                 headers={"Content-Type": "application/json"}),
                       self.call("GET", "/ui/../store.py")):
            bodies.append(json.dumps(result[1]))
        with open(os.path.join(self.data_dir, "board.json"), "w") as handle:
            handle.write("{broken")
        result = self.call("GET", "/api/board")
        self.assertEqual(self.assertError(result, 500), "board data is unreadable")
        bodies.append(json.dumps(result[1]))
        result = self.call("POST", "/api/card/create", {"title": "x"})
        self.assertError(result, 500)
        bodies.append(json.dumps(result[1]))
        with open(os.path.join(self.data_dir, "board.json")) as handle:
            self.assertEqual(handle.read(), "{broken")
        for text in bodies:
            self.assertNotIn(self.tmp, text)
            self.assertNotIn(os.path.realpath(self.tmp), text)
            self.assertNotIn("board.json", text)
            self.assertNotIn("Traceback", text)
            self.assertNotIn(".py", text)


class FlowTests(ServerTestCase):
    def test_end_to_end_and_persistence(self):
        card = self.create("fluxo", by="agente")
        cid = card["id"]
        self.ok("POST", "/api/card/move", {"id": cid, "column": "doing", "by": "agente"})
        self.ok("POST", "/api/card/comment", {"id": cid, "text": "andando", "by": "agente"})
        self.ok("POST", "/api/card/archive", {"id": cid})
        self.assertEqual(self.ok("GET", "/api/cards")["cards"], [])
        restored = self.ok("POST", "/api/card/restore", {"id": cid})
        self.assertEqual((restored["column"], restored["archived"]), ("doing", False))
        events = self.ok("GET", "/api/events")["events"]
        self.assertEqual([e["type"] for e in events],
                         ["card.create", "card.move", "card.comment", "card.archive",
                          "card.restore"])

        self.srv.stop()
        self.srv = Running(self.data_dir)
        again = self.ok("GET", "/api/card?id=" + cid)
        self.assertEqual(again["column"], "doing")
        self.assertEqual([c["text"] for c in again["comments"]], ["andando"])
        self.assertEqual(self.ok("GET", "/api/health")["revision"], 5)
        self.assertTrue(os.path.exists(os.path.join(self.data_dir, "BOARD.md")))

    def test_concurrent_creates(self):
        errors = []
        start = threading.Event()

        def worker(n):
            start.wait(WAIT)
            for i in range(5):
                status, value, _ = self.call("POST", "/api/card/create",
                                             {"title": "t%d-%d" % (n, i)})
                if status != 201:
                    errors.append(value)

        threads = [threading.Thread(target=worker, args=(n,)) for n in range(8)]
        for t in threads:
            t.start()
        start.set()
        for t in threads:
            t.join(WAIT * 3)
        self.assertEqual(errors, [])
        board = self.ok("GET", "/api/board")
        self.assertEqual(len(board["cards"]), 40)
        self.assertEqual(len({c["title"] for c in board["cards"]}), 40)
        self.assertEqual(board["revision"], 40)
        events = self.ok("GET", "/api/events")["events"]
        self.assertEqual([e["seq"] for e in events], list(range(1, 41)))


class StreamTests(ServerTestCase):
    def test_initial_document_and_live_create(self):
        self.create("antes")
        first = self.stream()
        doc = first.next("document")
        self.assertEqual(doc["revision"], 1)
        self.assertEqual([c["title"] for c in doc["cards"]], ["antes"])
        self.assertEqual([e["type"] for e in doc["events"]], ["card.create"])
        self.assertIsNone(first.response.getheader("Access-Control-Allow-Origin"))
        self.assertTrue(first.response.getheader("Content-Type").startswith("text/event-stream"))

        second = self.stream()
        self.assertEqual(second.next("document")["revision"], 1)
        card = self.create("depois", by="outro")
        doc = first.document_where(lambda d: d["revision"] >= 2)
        self.assertIn("depois", [c["title"] for c in doc["cards"]])
        last = doc["events"][-1]
        self.assertEqual((last["type"], last["card"], last["by"]),
                         ("card.create", card["id"], "outro"))
        self.assertLessEqual(len(doc["events"]), server.STREAM_EVENTS)
        self.assertGreaterEqual(second.document_where(lambda d: d["revision"] >= 2)["revision"], 2)

    def test_events_capped(self):
        reader = self.stream()
        reader.next("document")
        for i in range(25):
            self.create("c%d" % i)
        doc = reader.document_where(lambda d: d["revision"] == 25)
        self.assertEqual([e["seq"] for e in doc["events"]], list(range(6, 26)))

    def test_stream_rejects_bad_host(self):
        status, _, _ = self.call("GET", "/api/stream", headers={"Host": "evil.example"})
        self.assertEqual(status, 403)
        status, _, _ = self.call("GET", "/api/stream", headers={"Origin": "http://evil.example"})
        self.assertEqual(status, 403)

    def test_shutdown_closes_streams(self):
        reader = self.stream()
        reader.next("document")
        self.assertTrue(self.srv.httpd.hub.wait_clients(1, WAIT))
        self.srv.stop()
        self.assertFalse(self.srv.thread.is_alive())
        self.assertEqual(reader.next("eof"), None)
        self.assertTrue(self.srv.httpd.hub.wait_clients(0, WAIT))
        self.srv = Running(self.data_dir)


class PingTests(ServerTestCase):
    ping = 0.05

    def test_ping(self):
        reader = self.stream()
        reader.next("document")
        self.assertEqual(reader.next("comment"), "ping")
        self.assertEqual(reader.next("comment"), "ping")

    def test_dropped_client_is_removed(self):
        hub = self.srv.httpd.hub
        reader = self.stream()
        reader.next("document")
        self.assertTrue(hub.wait_clients(1, WAIT))
        reader.close()
        self.readers.remove(reader)
        self.assertTrue(hub.wait_clients(0, WAIT))
        self.create()
        self.assertEqual(self.ok("GET", "/api/health")["revision"], 1)
        other = self.stream()
        self.assertEqual(other.next("document")["revision"], 1)

    def test_other_process_write_reaches_stream(self):
        reader = self.stream()
        reader.next("document")
        Store(self.data_dir).create_card("de fora")
        doc = reader.document_where(lambda d: d["revision"] == 1)
        self.assertEqual([c["title"] for c in doc["cards"]], ["de fora"])


class MainTests(unittest.TestCase):
    def test_ping_must_be_positive(self):
        tmp = tempfile.mkdtemp(prefix="quadro-server-")
        try:
            with self.assertRaises(ValueError):
                server.serve(Store(tmp), ping=0)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_binds_loopback_only(self):
        tmp = tempfile.mkdtemp(prefix="quadro-server-")
        try:
            httpd = server.serve(Store(tmp))
            try:
                self.assertEqual(httpd.server_address[0], "127.0.0.1")
                self.assertGreater(httpd.port, 0)
                self.assertEqual(httpd.url, "http://127.0.0.1:%d" % httpd.port)
            finally:
                httpd.server_close()
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
