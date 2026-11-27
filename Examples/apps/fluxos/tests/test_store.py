import json
import os
import stat
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import store  # noqa: E402
from store import Invalid, Store, build_graph  # noqa: E402


def line(before, action, after, target="", version="1.0", app="com.example.shop"):
    return json.dumps({"t": "2026-11-26T10:00:00Z", "origin": "agent:a", "action": action, "target": target,
                       "sigBefore": before, "sigAfter": after, "app": app, "appVersion": version}, sort_keys=True)


def run(version="1.0"):
    """One agent run: home -> list -> cart -> checkout."""
    return [line("home", "tap", "list", "Produtos", version),
            line("list", "tap", "cart", "Carrinho", version),
            line("cart", "tap", "checkout", "Finalizar", version)]


def edge(graph, frm, to, version=None):
    found = [e for e in graph["edges"] if e["from"] == frm and e["to"] == to
             and (version is None or e["appVersion"] == version)]
    assert len(found) == 1, found
    return found[0]


class BuildGraphTests(unittest.TestCase):
    def test_three_runs_count_nodes_and_edges(self):
        g = build_graph(run() + run() + run())
        self.assertEqual(g["nodes"], ["cart", "checkout", "home", "list"])
        self.assertEqual(len(g["edges"]), 3)
        for e in g["edges"]:
            self.assertEqual(e["count"], 3)
            self.assertFalse(e["obsolete"])
        e = edge(g, "home", "list")
        self.assertEqual((e["action"], e["target"], e["app"], e["appVersion"]),
                         ("tap", "Produtos", "com.example.shop", "1.0"))
        self.assertEqual(g["skipped"], 0)

    def test_different_targets_are_different_edges(self):
        g = build_graph([line("home", "tap", "list", "Produtos"), line("home", "tap", "list", "Ver tudo")])
        self.assertEqual(sorted(e["target"] for e in g["edges"]), ["Produtos", "Ver tudo"])

    def test_malformed_lines_are_skipped(self):
        lines = run() + ["{quebrado", "[1,2]", "", "   ", json.dumps({"action": "tap"}),
                         json.dumps({"action": 3, "sigBefore": "a", "sigAfter": "b"}), b"\xff\xfe"] + run()
        g = build_graph(lines)
        self.assertEqual(g["skipped"], 5)   # blank lines are not malformed
        self.assertEqual(edge(g, "home", "list")["count"], 2)

    def test_newer_version_contradiction_marks_old_obsolete(self):
        g = build_graph(run("1.0") + [line("cart", "tap", "login", "Finalizar", "2.0")])
        old = edge(g, "cart", "checkout", "1.0")
        new = edge(g, "cart", "login", "2.0")
        self.assertTrue(old["obsolete"])
        self.assertFalse(new["obsolete"])
        self.assertEqual(old["count"], 1)   # kept, not deleted
        self.assertFalse(edge(g, "home", "list")["obsolete"])   # nothing newer contradicts it

    def test_same_destination_in_new_version_is_not_contradiction(self):
        g = build_graph(run("1.0") + run("2.0"))
        self.assertFalse(any(e["obsolete"] for e in g["edges"]))
        self.assertEqual(len(g["edges"]), 6)

    def test_other_app_does_not_contradict(self):
        g = build_graph(run("1.0") + [line("cart", "tap", "login", "Finalizar", "9.0", app="com.other")])
        self.assertFalse(any(e["obsolete"] for e in g["edges"]))


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def write_log(self, name, lines):
        os.makedirs(self.store.dir, exist_ok=True)
        with open(os.path.join(self.store.dir, name), "w") as handle:
            handle.write("\n".join(lines) + "\n")

    def test_learn_reads_rotated_logs_and_saves_0600(self):
        self.write_log("actions.1.jsonl", run())
        self.write_log("actions.jsonl", run() + ["nada"])
        g = self.store.learn()
        self.assertEqual(edge(g, "cart", "checkout")["count"], 2)
        self.assertEqual(g["skipped"], 1)
        self.assertEqual(stat.S_IMODE(os.stat(self.store.path).st_mode), 0o600)
        with open(self.store.path) as handle:
            self.assertEqual(json.load(handle), g)

    def test_goals_persist_and_survive_learn(self):
        self.store.set_goal("checkout", "checkout")
        self.store.set_goal("login", "login")
        self.assertEqual(Store(self.tmp.name).goals(), {"checkout": "checkout", "login": "login"})
        self.write_log("actions.jsonl", run())
        g = self.store.learn()
        self.assertEqual(g["goals"], {"checkout": "checkout", "login": "login"})
        self.assertEqual(Store(self.tmp.name).goals()["checkout"], "checkout")

    def test_goal_needs_name_and_sig(self):
        with self.assertRaises(Invalid):
            self.store.set_goal("", "x")
        with self.assertRaises(Invalid):
            self.store.set_goal("checkout", "  ")

    def test_empty_store(self):
        self.assertEqual(self.store.goals(), {})
        self.assertEqual(self.store.learn()["edges"], [])

    def test_atomic_write_never_leaves_half_file(self):
        self.store.set_goal("checkout", "checkout")
        with open(self.store.path, "rb") as handle:
            before = handle.read()
        with mock.patch.object(store.os, "replace", side_effect=OSError("disco cheio")):
            with self.assertRaises(OSError):
                self.store.set_goal("login", "login")
        with open(self.store.path, "rb") as handle:
            self.assertEqual(handle.read(), before)
        self.assertEqual(os.listdir(self.store.dir), ["graph.json"])   # the temp file is gone

    def test_write_failure_midway_keeps_old_file(self):
        self.store.set_goal("checkout", "checkout")
        real_fdopen = os.fdopen

        class Broken(object):
            def __init__(self, handle):
                self.handle = handle

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                self.handle.close()

            def write(self, data):
                self.handle.write(data[:5])
                raise OSError("falhou no meio")

        with mock.patch.object(store.os, "fdopen", lambda fd, mode: Broken(real_fdopen(fd, mode))):
            with self.assertRaises(OSError):
                self.store.set_goal("login", "login")
        self.assertEqual(Store(self.tmp.name).goals(), {"checkout": "checkout"})
        self.assertEqual(os.listdir(self.store.dir), ["graph.json"])


if __name__ == "__main__":
    unittest.main()
