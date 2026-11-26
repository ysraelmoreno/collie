"""collie.json against PluginManifest's rules, and the real server answering /healthz and go."""

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

NAME = re.compile(r"[a-z][a-z0-9-]{0,31}\Z")


def load():
    with open(os.path.join(HERE, "collie.json"), encoding="utf-8") as handle:
        return json.load(handle)


class ContractTests(unittest.TestCase):
    def test_valid_v2_with_the_four_commands(self):
        doc = load()
        self.assertEqual(doc["apiVersion"], 2)
        self.assertEqual(sorted(c["name"] for c in doc["commands"]), ["goals", "go", "learn", "show"])
        for c in doc["commands"]:
            self.assertRegex(c["name"], NAME)
            self.assertEqual(c["runs"], "http")
            self.assertTrue(c["http"]["path"].startswith("/api/"))
            for p in c.get("params", []):
                self.assertRegex(p["name"], NAME)

    def test_service_base_is_loopback(self):
        base = load()["service"]["base"]
        self.assertRegex(base, r"\Ahttp://(127\.0\.0\.1|localhost|\[::1\]):\d+\Z")

    def test_no_command_acts_on_the_device(self):
        for c in load()["commands"]:
            self.assertFalse(c.get("confirm", False), c["name"])
            self.assertNotIn("device", c["http"]["path"])
            self.assertIn(c["http"]["method"], ("GET", "POST"))
            if c["http"]["method"] == "POST":
                self.assertEqual(c["name"], "learn")   # the only write, and it writes graph.json only
        with open(os.path.join(HERE, "server.py"), encoding="utf-8") as handle:
            src = handle.read()
        for forbidden in ("subprocess", "adb", "socket.create_connection", "urlopen"):
            self.assertNotIn(forbidden, src)


class ServerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        flows = os.path.join(self.tmp.name, ".collie", "flows")
        os.makedirs(flows)
        lines = [{"action": "tap", "target": "Carrinho", "sigBefore": "home", "sigAfter": "cart", "app": "a", "appVersion": "1"},
                 {"action": "tap", "target": "Finalizar", "sigBefore": "cart", "sigAfter": "checkout", "app": "a", "appVersion": "1"},
                 {"action": "key", "target": "back", "sigBefore": "checkout", "sigAfter": "home", "app": "a", "appVersion": "1"}]
        with open(os.path.join(flows, "actions.jsonl"), "w") as handle:
            handle.write("\n".join(json.dumps(x) for x in lines) + "\n")
        self.store = Store(self.tmp.name)
        self.store.learn()
        self.store.set_goal("checkout", "checkout")
        self.srv = server.FluxosServer(self.store, port=0)
        self.thread = threading.Thread(target=self.srv.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()
        self.tmp.cleanup()

    def get(self, path, method="GET", host=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.srv.server_address[1], timeout=10)
        conn.request(method, path, headers={"Host": host} if host else {})
        r = conn.getresponse()
        body = json.loads(r.read())
        conn.close()
        return r.status, body

    def test_healthz_go_goals_show_learn(self):
        self.assertEqual(self.get("/healthz"), (200, {"ok": True}))
        status, body = self.get("/api/go?goal=checkout")   # from = last logged screen (home)
        self.assertEqual(status, 200, body)
        self.assertEqual(body["from"], "home")
        self.assertEqual([s["expectSig"] for s in body["plan"]["steps"]], ["cart", "checkout"])
        self.assertEqual(self.get("/api/go?goal=checkout&from=cart")[1]["plan"]["steps"],
                         [{"action": "tap", "target": "Finalizar", "expectSig": "checkout"}])
        status, body = self.get("/api/go?goal=login")
        self.assertEqual(status, 404)
        self.assertIn("meta desconhecida", body["error"])
        self.assertEqual(self.get("/api/goals")[1], {"goals": {"checkout": "checkout"}})
        self.assertEqual(len(self.get("/api/show?goal=checkout")[1]["in"]), 1)
        status, body = self.get("/api/learn", method="POST")
        self.assertEqual((status, body["edges"], body["goals"]), (200, 3, {"checkout": "checkout"}))

    def test_foreign_host_refused(self):
        self.assertEqual(self.get("/healthz", host="evil.example")[0], 403)


if __name__ == "__main__":
    unittest.main()
