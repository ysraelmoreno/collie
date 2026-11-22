"""The agent contract (collie.json) against the real server, plus run.sh and the README."""

import http.client
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from urllib.parse import urlencode

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)

import server  # noqa: E402
from store import Store  # noqa: E402

TYPES = ("impl", "bug", "refactor", "spike", "test", "docs", "chore")
PRIORITIES = ("high", "medium", "low")
COMMANDS = ("board", "list-cards", "get-card", "create-card", "update-card", "move-card", "comment-card",
            "archive-card", "restore-card", "events")
WRITES = ("create-card", "update-card", "move-card", "comment-card", "archive-card", "restore-card")
NAME = re.compile(r"[a-z][a-z0-9-]{0,31}\Z")  # PluginManifest's command and param names


def load():
    with open(os.path.join(HERE, "collie.json"), encoding="utf-8") as handle:
        return json.load(handle)


class ContractShapeTests(unittest.TestCase):
    def test_decodes_with_unique_named_commands(self):
        doc = load()
        names = [c["name"] for c in doc["commands"]]
        self.assertEqual(len(names), len(set(names)))
        self.assertEqual(set(names), {"board", "list-cards", "get-card", "events"} | set(WRITES))
        for c in doc["commands"]:
            self.assertRegex(c["name"], NAME)
            self.assertTrue(c["summary"].strip(), c["name"])
            self.assertEqual(c["runs"], "http")
            self.assertIn(c["http"]["method"], ("GET", "POST"))
            self.assertFalse(c.get("confirm", False), c["name"])
            for p in c.get("params", []):
                self.assertRegex(p["name"], NAME)
                self.assertNotEqual(p["name"], "panel")
                self.assertIn(p["type"], ("string", "int", "flag", "rest"))

    def test_writes_stay_in_contract(self):
        names = {c["name"]: c for c in load()["commands"]}
        for w in WRITES:
            self.assertIn(w, names)
            self.assertEqual(names[w]["http"]["method"], "POST")

    def test_still_the_ten_commands(self):
        self.assertEqual(sorted(c["name"] for c in load()["commands"]), sorted(COMMANDS))

    def test_type_and_priority_params(self):
        names = {c["name"]: c for c in load()["commands"]}
        for cmd in ("create-card", "update-card", "list-cards"):
            params = {p["name"]: p for p in names[cmd]["params"]}
            for key, values in (("type", TYPES), ("priority", PRIORITIES)):
                self.assertIn(key, params, cmd)
                p = params[key]
                self.assertEqual(p["type"], "string", cmd)
                self.assertFalse(p.get("required", False), cmd)
                self.assertFalse(p.get("positional", False), cmd)
                for v in values:
                    self.assertRegex(p["help"], r"\b%s\b" % v, "%s --%s" % (cmd, key))
        create = {p["name"]: p for p in names["create-card"]["params"]}
        self.assertIn("padrão impl", create["type"]["help"])
        self.assertIn("padrão medium", create["priority"]["help"])
        for cmd in set(COMMANDS) - {"create-card", "update-card", "list-cards"}:
            keys = {p["name"] for p in names[cmd].get("params", [])}
            self.assertFalse(keys & {"type", "priority"}, cmd)

    def test_events(self):
        doc = load()
        self.assertEqual(doc["eventStream"], "/api/stream")
        self.assertEqual(doc["eventDiff"], "events")
        self.assertEqual(doc["events"], ["quadro.event"])


class ContractServerTests(unittest.TestCase):
    """Calls every command the way Collie does: GET params in the query, POST params as a JSON body."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.httpd = server.serve(Store(self.dir), port=0)
        self.thread = threading.Thread(target=self.httpd.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(10)
        shutil.rmtree(self.dir, ignore_errors=True)

    def call(self, command, args):
        method, path = command["http"]["method"], command["http"]["path"]
        conn = http.client.HTTPConnection("127.0.0.1", self.httpd.port, timeout=10)
        try:
            if method == "GET":
                text = {k: ("true" if v is True else str(v)) for k, v in args.items()}
                conn.request("GET", path + ("?" + urlencode(text) if text else ""), headers={"Accept": "application/json"})
            else:
                conn.request(method, path, body=json.dumps(args).encode("utf-8"),
                             headers={"Content-Type": "application/json", "Accept": "application/json"})
            resp = conn.getresponse()
            return resp.status, json.loads(resp.read().decode("utf-8"))
        finally:
            conn.close()

    def test_every_command_is_served(self):
        cmds = {c["name"]: c for c in load()["commands"]}
        status, card = self.call(cmds["create-card"], {"title": "Agent card", "body": "b", "column": "todo",
                                                       "labels": "bug, ui", "assignee": "ana", "by": "agent-1"})
        self.assertEqual(status, 201)
        self.assertEqual(card["labels"], ["bug", "ui"])
        cid = card["id"]
        samples = [
            ("board", {"archived": True}),
            ("list-cards", {"column": "todo", "label": "bug", "assignee": "ana", "q": "Agent"}),
            ("get-card", {"id": cid}),
            ("update-card", {"id": cid, "title": "Renamed", "labels": "bug", "by": "agent-1"}),
            ("move-card", {"id": cid, "column": "doing", "index": 0.0, "by": "agent-1"}),
            ("comment-card", {"id": cid, "text": "on it", "by": "agent-1"}),
            ("archive-card", {"id": cid, "by": "agent-1"}),
            ("restore-card", {"id": cid, "by": "agent-1"}),
            ("events", {"since": 0}),
        ]
        self.assertEqual({n for n, _ in samples} | {"create-card"}, set(cmds))
        for name, args in samples:
            declared = {p["name"] for p in cmds[name].get("params", [])}
            self.assertLessEqual(set(args), declared, name)
            status, body = self.call(cmds[name], args)
            self.assertEqual(status, 200, "%s: %s" % (name, body))
        _, final = self.call(cmds["get-card"], {"id": cid})
        self.assertEqual((final["title"], final["column"], final["archived"]), ("Renamed", "doing", False))
        self.assertEqual(len(final["comments"]), 1)
        _, board = self.call(cmds["board"], {})
        self.assertIn("columns", board)


    def test_type_and_priority_through_commands(self):
        cmds = {c["name"]: c for c in load()["commands"]}
        status, plain = self.call(cmds["create-card"], {"title": "Defaults"})
        self.assertEqual(status, 201, plain)
        self.assertEqual((plain["type"], plain["priority"]), ("impl", "medium"))
        made = {}
        for i, kind in enumerate(TYPES):
            level = PRIORITIES[i % len(PRIORITIES)]
            status, card = self.call(cmds["create-card"], {"title": "T " + kind, "type": kind, "priority": level,
                                                           "by": "agent-1"})
            self.assertEqual(status, 201, card)
            self.assertEqual((card["type"], card["priority"]), (kind, level))
            made[card["id"]] = (kind, level)
        for level in PRIORITIES:
            status, card = self.call(cmds["update-card"], {"id": plain["id"], "priority": level, "by": "agent-1"})
            self.assertEqual(status, 200, card)
            self.assertEqual((card["type"], card["priority"]), ("impl", level))
        for kind in TYPES:
            status, card = self.call(cmds["update-card"], {"id": plain["id"], "type": kind})
            self.assertEqual(status, 200, card)
            self.assertEqual((card["type"], card["priority"]), (kind, "low"))
        self.call(cmds["update-card"], {"id": plain["id"], "type": "impl", "priority": "medium"})
        made[plain["id"]] = ("impl", "medium")
        for kind in TYPES:
            status, body = self.call(cmds["list-cards"], {"type": kind})
            self.assertEqual(status, 200, body)
            self.assertEqual({c["id"] for c in body["cards"]}, {i for i, v in made.items() if v[0] == kind}, kind)
        for level in PRIORITIES:
            status, body = self.call(cmds["list-cards"], {"priority": level})
            self.assertEqual(status, 200, body)
            self.assertEqual({c["id"] for c in body["cards"]}, {i for i, v in made.items() if v[1] == level}, level)
        status, body = self.call(cmds["list-cards"], {"type": "bug", "priority": "medium"})
        self.assertEqual(status, 200, body)
        self.assertEqual({c["id"] for c in body["cards"]}, {i for i, v in made.items() if v == ("bug", "medium")})
        status, body = self.call(cmds["get-card"], {"id": plain["id"]})
        self.assertEqual((status, body["type"], body["priority"]), (200, "impl", "medium"))
        _, board = self.call(cmds["board"], {})
        for card in board["cards"]:
            self.assertIn(card["type"], TYPES)
            self.assertIn(card["priority"], PRIORITIES)

    def test_invalid_type_or_priority_is_400(self):
        cmds = {c["name"]: c for c in load()["commands"]}
        _, card = self.call(cmds["create-card"], {"title": "Ok"})
        bad = [
            ("create-card", {"title": "x", "type": "feature"}, "tipo inválido"),
            ("create-card", {"title": "x", "priority": "urgent"}, "prioridade inválida"),
            ("update-card", {"id": card["id"], "type": "IMPL"}, "tipo inválido"),
            ("update-card", {"id": card["id"], "priority": ""}, "prioridade inválida"),
        ]
        for name, args, message in bad:
            status, body = self.call(cmds[name], args)
            self.assertEqual((status, body.get("error")), (400, message), "%s %s" % (name, args))
        _, after = self.call(cmds["get-card"], {"id": card["id"]})
        self.assertEqual((after["type"], after["priority"]), ("impl", "medium"))
        _, listed = self.call(cmds["list-cards"], {})
        self.assertEqual(len(listed["cards"]), 1)


class RunScriptTests(unittest.TestCase):
    def test_executable_and_parses(self):
        path = os.path.join(HERE, "run.sh")
        self.assertTrue(os.access(path, os.X_OK))
        subprocess.run(["bash", "-n", path], check=True)
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        self.assertIn("set -euo pipefail", text)
        self.assertIn('QUADRO_PORT:-8791', text)
        self.assertIn('$HOME/.collie/quadro', text)


class ReadmeTests(unittest.TestCase):
    def test_no_personal_paths_or_internal_names(self):
        with open(os.path.join(HERE, "README.md"), encoding="utf-8") as handle:
            text = handle.read()
        for bad in ("/Users/", "/home/", "paddocks/", "lane-", "my-orchestrator", ".collie/paddocks"):
            self.assertNotIn(bad, text)
        self.assertIn("collie app adopt quadro", text)
        self.assertIn("collie app attach quadro", text)
        for word in ("Collie Main", "Pastor", "onda12", "Q12."):
            self.assertNotIn(word, text)

    def test_documents_types_priorities_and_migration(self):
        with open(os.path.join(HERE, "README.md"), encoding="utf-8") as handle:
            text = handle.read()
        for v in TYPES + PRIORITIES:
            self.assertIn("`%s`" % v, text)
        self.assertIn("board.json.v1.bak", text)
        self.assertIn("--type", text)
        self.assertIn("--priority", text)


if __name__ == "__main__":
    unittest.main()
