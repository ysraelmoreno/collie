"""The panel: served at / as HTML, no external host, and the README states the contract (d10)."""

import http.client
import json
import os
import re
import sys
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)

import server  # noqa: E402
from store import Store  # noqa: E402

URL = re.compile(r"https?://([^/\s\"'<>:]+)", re.I)
LOOPBACK = {"127.0.0.1", "localhost", "[::1]"}


def read(*parts):
    with open(os.path.join(HERE, *parts), encoding="utf-8") as handle:
        return handle.read()


class UITests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.flows = os.path.join(self.tmp.name, ".collie", "flows")
        os.makedirs(self.flows)
        with open(os.path.join(self.flows, "actions.jsonl"), "w") as handle:
            handle.write(json.dumps({"action": "tap", "target": "Carrinho", "sigBefore": "home", "sigAfter": "cart",
                                     "app": "a", "appVersion": "1"}) + "\n")
        self.store = Store(self.tmp.name)
        self.store.learn()
        self.srv = server.FluxosServer(self.store, port=0)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()
        self.tmp.cleanup()

    def get(self, path):
        conn = http.client.HTTPConnection("127.0.0.1", self.srv.server_address[1], timeout=10)
        conn.request("GET", path)
        r = conn.getresponse()
        body = r.read()
        conn.close()
        return r.status, r.getheader("Content-Type"), body

    def test_serves_root_as_html(self):
        status, ctype, body = self.get("/")
        self.assertEqual(status, 200)
        self.assertTrue(ctype.startswith("text/html"), ctype)
        self.assertIn(b"<table", body)
        self.assertIn(b"api/graph", body)
        self.assertIn(b"api/status", body)

    def test_page_references_no_external_host(self):
        for name in os.listdir(os.path.join(HERE, "ui")):
            hosts = {h.lower() for h in URL.findall(read("ui", name))}
            self.assertEqual(hosts - LOOPBACK, set(), name)
        self.assertNotIn("innerHTML", read("ui", "index.html"))   # app data goes in as text only

    def test_status_and_graph_for_the_panel(self):
        status, _, body = self.get("/api/status")
        self.assertEqual(status, 200)
        s = json.loads(body)
        self.assertFalse(s["enabled"])
        self.assertGreater(s["bytes"], 0)
        self.assertTrue(s["path"].endswith(os.path.join(".collie", "flows", "actions.jsonl")))
        open(os.path.join(self.flows, "enabled"), "w").close()   # what `collie device flow on` creates
        self.assertTrue(json.loads(self.get("/api/status")[2])["enabled"])
        g = json.loads(self.get("/api/graph")[2])
        self.assertEqual(sorted(g["nodes"]), ["cart", "home"])
        self.assertEqual(g["edges"][0]["target"], "Carrinho")

    def test_readme_states_the_contract(self):
        doc = " ".join(read("README.md").split())
        self.assertIn("actions.jsonl", doc)
        self.assertIn("Opt-in", doc)
        self.assertIn("`flow go` only returns a plan", doc)
        self.assertIn("Owner's manual run (3 steps)", doc)


if __name__ == "__main__":
    unittest.main()
