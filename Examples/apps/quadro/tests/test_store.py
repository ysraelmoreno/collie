import json
import os
import stat
import sys
import tempfile
import threading
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import store  # noqa: E402
from store import Invalid, NotFound, Store, StoreCorrupt  # noqa: E402


def journal(s):
    path = os.path.join(s.dir, "events.jsonl")
    with open(path) as handle:
        return [json.loads(line) for line in handle if line.strip()]


class StoreTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = os.path.join(self._tmp.name, "data")
        self.store = Store(self.dir)

    def tearDown(self):
        self._tmp.cleanup()

    def ids(self, column):
        return [c["id"] for c in self.store.cards(column=column)]


class CrudTests(StoreTestCase):
    def test_create_and_read(self):
        card = self.store.create_card("Primeiro", body="corpo", labels=["a", "b"],
                                      assignee="ana", by="agente-1")
        self.assertRegex(card["id"], r"^[0-9a-f]{8}$")
        self.assertEqual(card["column"], "todo")
        self.assertEqual(card["createdBy"], "agente-1")
        self.assertFalse(card["archived"])
        self.assertEqual(card["comments"], [])
        self.assertEqual(self.store.card(card["id"]), card)
        self.assertEqual(self.store.revision, 1)
        board = self.store.board()
        self.assertEqual([c["id"] for c in board["columns"]], ["todo", "doing", "review", "done"])
        self.assertEqual(board["schema"], 2)

    def test_update(self):
        card = self.store.create_card("t")
        out = self.store.update_card(card["id"], title="novo", body="b", labels=["x"],
                                     assignee="bia", by="ag")
        self.assertEqual((out["title"], out["body"], out["labels"], out["assignee"]),
                         ("novo", "b", ["x"], "bia"))
        self.assertEqual(self.store.card(card["id"])["title"], "novo")
        self.assertEqual(journal(self.store)[-1]["detail"]["fields"],
                         ["assignee", "body", "labels", "title"])

    def test_update_without_change_has_no_event(self):
        card = self.store.create_card("t")
        self.store.update_card(card["id"], title="t")
        self.assertEqual(self.store.revision, 1)
        self.assertEqual(len(journal(self.store)), 1)

    def test_update_unknown_field(self):
        card = self.store.create_card("t")
        with self.assertRaises(Invalid):
            self.store.update_card(card["id"], column="done")

    def test_move_order_end_and_other_column(self):
        a = self.store.create_card("a")["id"]
        b = self.store.create_card("b")["id"]
        c = self.store.create_card("c")["id"]
        self.assertEqual(self.ids("todo"), [a, b, c])
        self.store.move_card(c, "todo", index=0)
        self.assertEqual(self.ids("todo"), [c, a, b])
        self.store.move_card(c, "todo")
        self.assertEqual(self.ids("todo"), [a, b, c])
        self.store.move_card(a, "todo", index=1)
        self.assertEqual(self.ids("todo"), [b, a, c])
        moved = self.store.move_card(b, "doing", by="ag")
        self.assertEqual(moved["column"], "doing")
        self.assertEqual(self.ids("doing"), [b])
        self.store.move_card(a, "doing", index=0)
        self.assertEqual(self.ids("doing"), [a, b])
        self.assertEqual(self.ids("todo"), [c])
        self.store.move_card(c, "doing", index=99)
        self.assertEqual(self.ids("doing"), [a, b, c])
        last = journal(self.store)[-1]
        self.assertEqual(last["type"], "card.move")
        self.assertEqual(last["detail"], {"from": "todo", "to": "doing", "index": 2})

    def test_move_same_place_is_noop(self):
        a = self.store.create_card("a")["id"]
        self.store.create_card("b")
        self.store.move_card(a, "todo", index=0)
        self.assertEqual(self.store.revision, 2)
        self.assertEqual(len(journal(self.store)), 2)

    def test_move_invalid(self):
        a = self.store.create_card("a")["id"]
        with self.assertRaises(Invalid):
            self.store.move_card(a, "nope")
        with self.assertRaises(Invalid):
            self.store.move_card(a, "doing", index=-1)
        with self.assertRaises(Invalid):
            self.store.move_card(a, "doing", index="1")

    def test_comment(self):
        a = self.store.create_card("a")["id"]
        card = self.store.comment(a, "olá", by="ag")
        self.assertEqual(len(card["comments"]), 1)
        self.assertEqual(card["comments"][0]["text"], "olá")
        self.assertEqual(card["comments"][0]["by"], "ag")
        self.assertRegex(card["comments"][0]["id"], r"^[0-9a-f]{8}$")

    def test_archive_restore(self):
        a = self.store.create_card("a")["id"]
        self.assertTrue(self.store.archive(a)["archived"])
        self.assertEqual(self.store.cards(), [])
        self.assertEqual(self.store.board()["cards"], [])
        self.assertEqual(len(self.store.board(include_archived=True)["cards"]), 1)
        self.assertTrue(self.store.card(a)["archived"])
        rev = self.store.revision
        self.store.archive(a)
        self.assertEqual(self.store.revision, rev)
        self.assertFalse(self.store.restore(a)["archived"])
        self.assertEqual(len(self.store.cards()), 1)
        self.store.restore(a)
        self.assertEqual(self.store.revision, rev + 1)
        self.assertEqual([e["type"] for e in journal(self.store)],
                         ["card.create", "card.archive", "card.restore"])

    def test_filters(self):
        a = self.store.create_card("Corrigir Login", labels=["bug"], assignee="ana")["id"]
        b = self.store.create_card("Outra", body="tem LOGIN no corpo", column="doing")["id"]
        c = self.store.create_card("Terceira", labels=["Login-x"])["id"]
        d = self.store.create_card("Quarta")["id"]
        self.store.comment(d, "falar do login")
        self.store.create_card("nada")
        self.assertEqual([x["id"] for x in self.store.cards(q="login")], [a, b, c, d])
        self.assertEqual([x["id"] for x in self.store.cards(column="doing")], [b])
        self.assertEqual([x["id"] for x in self.store.cards(label="bug")], [a])
        self.assertEqual([x["id"] for x in self.store.cards(assignee="ana")], [a])
        self.store.archive(a)
        self.assertEqual([x["id"] for x in self.store.cards(q="login")], [b, c, d])

    def test_not_found(self):
        for call in (lambda: self.store.card("deadbeef"),
                     lambda: self.store.update_card("deadbeef", title="x"),
                     lambda: self.store.move_card("deadbeef", "todo"),
                     lambda: self.store.comment("deadbeef", "x"),
                     lambda: self.store.archive("deadbeef"),
                     lambda: self.store.restore("deadbeef")):
            with self.assertRaises(NotFound):
                call()


class LimitTests(StoreTestCase):
    def test_limits(self):
        cases = [
            dict(title=""), dict(title="   "), dict(title="x" * 201), dict(title=5),
            dict(title="ok", body="x" * 8001),
            dict(title="ok", labels=["l"] * 0 + [str(i) for i in range(11)]),
            dict(title="ok", labels=["x" * 33]), dict(title="ok", labels=[""]),
            dict(title="ok", labels="abc"),
            dict(title="ok", assignee="x" * 65),
            dict(title="ok", by="x" * 65),
            dict(title="ok", column="nope"),
        ]
        for kwargs in cases:
            with self.subTest(kwargs=kwargs):
                with self.assertRaises(Invalid):
                    self.store.create_card(**kwargs)
        self.assertEqual(self.store.revision, 0)
        self.assertFalse(os.path.exists(os.path.join(self.dir, "board.json")))

    def test_limits_at_edge_are_fine(self):
        card = self.store.create_card("x" * 200, body="y" * 8000,
                                      labels=["z" * 32] * 1 + [str(i) for i in range(9)],
                                      assignee="a" * 64, by="b" * 64)
        self.assertEqual(len(card["title"]), 200)

    def test_comment_limits(self):
        a = self.store.create_card("a")["id"]
        for text in ("", "x" * 2001):
            with self.assertRaises(Invalid):
                self.store.comment(a, text)
        self.store.comment(a, "x" * 2000)
        with mock.patch.object(store, "MAX_COMMENTS", 2):
            self.store.comment(a, "ok")
            with self.assertRaises(Invalid):
                self.store.comment(a, "um a mais")

    def test_card_count_limit(self):
        with mock.patch.object(store, "MAX_CARDS", 2):
            self.store.create_card("a")
            self.store.create_card("b")
            with self.assertRaises(Invalid):
                self.store.create_card("c")

    def test_by_control_chars_are_cleaned(self):
        card = self.store.create_card("a", by="ag\x00en\x1bte\n-1\x7f")
        self.assertEqual(card["createdBy"], "agente-1")
        self.assertEqual(journal(self.store)[-1]["by"], "agente-1")
        out = self.store.comment(card["id"], "oi", by="\tbo\rt")
        self.assertEqual(out["comments"][0]["by"], "bot")


class RevisionTests(StoreTestCase):
    def test_revision_and_seq_match_journal(self):
        a = self.store.create_card("a", by="x")["id"]
        self.assertEqual(self.store.revision, 1)
        self.store.update_card(a, body="b")
        self.assertEqual(self.store.revision, 2)
        self.store.move_card(a, "done")
        self.assertEqual(self.store.revision, 3)
        self.store.comment(a, "c")
        self.store.archive(a)
        self.store.restore(a)
        self.assertEqual(self.store.revision, 6)
        events = journal(self.store)
        self.assertEqual([e["seq"] for e in events], [1, 2, 3, 4, 5, 6])
        self.assertEqual(self.store.events(), events)
        self.assertEqual([e["seq"] for e in self.store.events(since=4)], [5, 6])
        self.assertEqual([e["seq"] for e in self.store.events(since=1, limit=2)], [2, 3])
        first = events[0]
        self.assertEqual(set(first), {"seq", "at", "by", "type", "card", "detail"})
        self.assertEqual((first["type"], first["card"], first["by"]), ("card.create", a, "x"))

    def test_events_limit_capped(self):
        with mock.patch.object(store, "EVENTS_PAGE", 3):
            for i in range(5):
                self.store.create_card(str(i))
            self.assertEqual(len(self.store.events(limit=1000)), 3)
        with self.assertRaises(Invalid):
            self.store.events(since=-1)


class PersistenceTests(StoreTestCase):
    def test_existing_folder_keeps_its_mode(self):
        # review Q1: QUADRO_DIR may name a folder the user already had; only a folder the store made becomes 0700
        shared = os.path.join(self._tmp.name, "shared")
        os.mkdir(shared)
        os.chmod(shared, 0o755)
        Store(shared)
        self.assertEqual(os.stat(shared).st_mode & 0o777, 0o755)
        self.assertEqual(os.stat(self.dir).st_mode & 0o777, 0o700)

    def test_reopen_returns_same_board(self):
        a = self.store.create_card("a", labels=["l"])["id"]
        self.store.create_card("b", column="review")
        self.store.comment(a, "c")
        self.store.archive(a)
        before = self.store.board(include_archived=True)
        again = Store(self.dir)
        self.assertEqual(again.board(include_archived=True), before)
        self.assertEqual(again.revision, 4)
        again.create_card("c")
        self.assertEqual([e["seq"] for e in again.events()], [1, 2, 3, 4, 5])

    def test_two_stores_alternating_lose_nothing(self):
        other = Store(self.dir)
        made = []
        for i in range(10):
            writer = self.store if i % 2 == 0 else other
            made.append(writer.create_card("c%d" % i)["id"])
        for i, card_id in enumerate(made):
            writer = other if i % 2 == 0 else self.store
            writer.comment(card_id, "de %d" % i)
        for s in (self.store, other):
            self.assertEqual(s.revision, 20)
            self.assertEqual([c["id"] for c in s.cards()], made)
            self.assertTrue(all(len(c["comments"]) == 1 for c in s.cards()))
        self.assertEqual([e["seq"] for e in other.events()], list(range(1, 21)))

    def test_threads_lose_nothing(self):
        def work(n):
            for i in range(10):
                self.store.create_card("t%d-%d" % (n, i))

        threads = [threading.Thread(target=work, args=(n,)) for n in range(4)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(self.store.revision, 40)
        self.assertEqual(len(self.store.cards()), 40)


class AtomicityTests(StoreTestCase):
    def test_failed_replace_keeps_old_board(self):
        self.store.create_card("a")
        path = os.path.join(self.dir, "board.json")
        with open(path, "rb") as handle:
            before = handle.read()

        def boom(src, dst):
            raise OSError("disco cheio")

        with mock.patch.object(store.os, "replace", boom):
            with self.assertRaises(OSError):
                self.store.create_card("b")
        with open(path, "rb") as handle:
            self.assertEqual(handle.read(), before)
        self.assertEqual(sorted(os.listdir(self.dir)),
                         ["BOARD.md", "board.json", "board.lock", "events.jsonl"])
        self.assertEqual(self.store.revision, 1)
        self.assertEqual(len(journal(self.store)), 1)

    def test_corrupt_board_is_left_untouched(self):
        path = os.path.join(self.dir, "board.json")
        for raw in (b"{not json", b"[1, 2]", b'{"revision": "x", "columns": [], "cards": []}',
                    b"\xff\xfe"):
            with self.subTest(raw=raw):
                with open(path, "wb") as handle:
                    handle.write(raw)
                for call in (lambda: self.store.board(), lambda: self.store.cards(),
                             lambda: self.store.revision,
                             lambda: self.store.create_card("a")):
                    with self.assertRaises(StoreCorrupt):
                        call()
                with open(path, "rb") as handle:
                    self.assertEqual(handle.read(), raw)
                self.assertFalse(os.path.exists(os.path.join(self.dir, "events.jsonl")))

    def test_journal_and_mirror_failure_do_not_fail_change(self):
        os.mkdir(os.path.join(self.dir, "events.jsonl"))
        os.mkdir(os.path.join(self.dir, "BOARD.md"))
        card = self.store.create_card("a")
        self.assertEqual(self.store.card(card["id"])["title"], "a")
        self.assertEqual(self.store.revision, 1)
        self.assertEqual([x for x in os.listdir(self.dir) if x.startswith(".tmp-")], [])


class MirrorTests(StoreTestCase):
    def mirror(self):
        with open(os.path.join(self.dir, "BOARD.md")) as handle:
            return handle.read()

    def test_mirror_lists_cards(self):
        self.store.create_card("Primeiro", column="doing")
        text = self.mirror()
        self.assertIn("## Em andamento (1)", text)
        self.assertIn("- Primeiro (", text)

    def test_mirror_escapes_agent_text(self):
        evil = "# x\n- [a](http://b) <script>`code`</script>"
        card = self.store.create_card(evil, body=evil, by="# by\n[z](http://y)")
        self.store.comment(card["id"], evil, by="<b>`ag`</b>\n# h")
        text = self.mirror()
        lines = text.split("\n")
        headings = [ln for ln in lines if ln.startswith("#")]
        self.assertEqual(headings, ["# Quadro", "## A fazer (1)", "## Em andamento (0)",
                                    "## Em revisão (0)", "## Feito (0)"])
        self.assertNotIn("](", text.replace("\\](", ""))
        self.assertNotIn("](http", text)
        self.assertNotRegex(text, r"(?<!\\)<script")
        self.assertNotRegex(text, r"(?<!\\)<b>")
        self.assertNotRegex(text, r"(?<!\\)`")
        self.assertNotRegex(text, r"(?<!\\)\[")
        self.assertNotRegex(text, r"(?<!\\)<")
        self.assertNotIn("\n- [a]", text)
        self.assertNotIn("\n# x", text)
        self.assertIn("\\# x \\- \\[a\\]\\(http\\:\\/\\/b\\)", text)
        self.assertEqual(len([ln for ln in lines if "script" in ln]), 3)

    def test_md_escape(self):
        self.assertEqual(store.md_escape("a\nb\r\tc"), "a b c")
        self.assertEqual(store.md_escape("#[<`"), "\\#\\[\\<\\`")


class JournalRotationTests(StoreTestCase):
    def test_rotation_keeps_one_old_file(self):
        small = Store(self.dir, journal_limit=600)
        for i in range(12):
            small.create_card("cartão %d" % i)
        new = os.path.join(self.dir, "events.jsonl")
        old = os.path.join(self.dir, "events.1.jsonl")
        self.assertTrue(os.path.exists(old))
        self.assertLessEqual(os.path.getsize(new), 600)
        self.assertLessEqual(os.path.getsize(old), 600)
        self.assertEqual(sorted(n for n in os.listdir(self.dir) if n.startswith("events")),
                         ["events.1.jsonl", "events.jsonl"])
        self.assertFalse(os.path.exists(os.path.join(self.dir, "events.2.jsonl")))
        seqs = [e["seq"] for e in small.events()]
        self.assertEqual(seqs, list(range(seqs[0], 13)))
        self.assertGreater(seqs[0], 1)
        self.assertEqual(stat.S_IMODE(os.stat(old).st_mode), 0o600)


class PermissionTests(StoreTestCase):
    def test_permissions(self):
        a = self.store.create_card("a")["id"]
        self.store.comment(a, "c")
        self.assertEqual(stat.S_IMODE(os.stat(self.dir).st_mode), 0o700)
        for name in ("board.json", "BOARD.md", "events.jsonl", "board.lock"):
            with self.subTest(name=name):
                mode = os.stat(os.path.join(self.dir, name)).st_mode
                self.assertEqual(stat.S_IMODE(mode), 0o600)

    def test_existing_loose_dir_is_left_alone(self):
        # review Q1: a folder that was already there keeps its mode (the files inside stay 0600)
        loose = os.path.join(self._tmp.name, "loose")
        os.mkdir(loose)
        os.chmod(loose, 0o755)
        Store(loose).create_card("x")
        self.assertEqual(stat.S_IMODE(os.stat(loose).st_mode), 0o755)
        self.assertEqual(stat.S_IMODE(os.stat(os.path.join(loose, "board.json")).st_mode), 0o600)

    def test_default_dir_uses_env(self):
        with mock.patch.dict(os.environ, {"QUADRO_DIR": self.dir}):
            self.assertEqual(Store().dir, os.path.abspath(self.dir))


class TypePriorityTests(StoreTestCase):
    def test_defaults_and_explicit(self):
        plain = self.store.create_card("a")
        self.assertEqual((plain["type"], plain["priority"]), ("impl", "medium"))
        made = self.store.create_card("b", type="bug", priority="high")
        self.assertEqual((made["type"], made["priority"]), ("bug", "high"))
        self.assertEqual(self.store.card(made["id"])["type"], "bug")
        self.assertEqual(journal(self.store)[-1]["detail"]["type"], "bug")
        self.assertEqual(journal(self.store)[-1]["detail"]["priority"], "high")
        self.assertEqual(store.TYPES,
                         ("impl", "bug", "refactor", "spike", "test", "docs", "chore"))
        self.assertEqual(store.PRIORITIES, ("high", "medium", "low"))

    def test_invalid_values(self):
        for bad in ("Bug", "", "feature", 3, None):
            with self.subTest(bad=bad):
                with self.assertRaisesRegex(Invalid, "tipo inválido"):
                    self.store.create_card("a", type=bad)
                with self.assertRaisesRegex(Invalid, "prioridade inválida"):
                    self.store.create_card("a", priority=bad)
        card = self.store.create_card("a")
        with self.assertRaisesRegex(Invalid, "tipo inválido"):
            self.store.update_card(card["id"], type="x")
        with self.assertRaisesRegex(Invalid, "prioridade inválida"):
            self.store.update_card(card["id"], priority="urgent")
        self.assertEqual(self.store.revision, 1)

    def test_update_one_field(self):
        card = self.store.create_card("a", type="spike", priority="low")
        out = self.store.update_card(card["id"], priority="high", by="ag")
        self.assertEqual((out["type"], out["priority"]), ("spike", "high"))
        last = journal(self.store)[-1]
        self.assertEqual((last["type"], last["by"], last["detail"]),
                         ("card.update", "ag", {"fields": ["priority"], "priority": "high"}))
        out = self.store.update_card(card["id"], type="docs", priority=None)
        self.assertEqual((out["type"], out["priority"]), ("docs", "high"))
        self.assertEqual(journal(self.store)[-1]["detail"], {"fields": ["type"], "type": "docs"})
        rev = self.store.revision
        self.store.update_card(card["id"], type="docs", priority="high")
        self.assertEqual(self.store.revision, rev)
        self.assertEqual(len(journal(self.store)), rev)

    def test_filters(self):
        a = self.store.create_card("a", type="bug", priority="high")["id"]
        b = self.store.create_card("b", type="bug", priority="low")["id"]
        c = self.store.create_card("c", priority="high", column="doing")["id"]
        ids = lambda **kw: [x["id"] for x in self.store.cards(**kw)]  # noqa: E731
        self.assertEqual(ids(type="bug"), [a, b])
        self.assertEqual(ids(priority="high"), [a, c])
        self.assertEqual(ids(type="bug", priority="high"), [a])
        self.assertEqual(ids(type="impl", column="doing"), [c])
        self.assertEqual(ids(type="chore"), [])

    def test_schema2_card_without_fields_reads_default(self):
        self.store.create_card("a")
        path = os.path.join(self.dir, "board.json")
        with open(path) as handle:
            doc = json.load(handle)
        del doc["cards"][0]["type"]
        del doc["cards"][0]["priority"]
        with open(path, "w") as handle:
            json.dump(doc, handle)
        card = self.store.cards()[0]
        self.assertEqual((card["type"], card["priority"]), ("impl", "medium"))
        self.assertEqual(self.store.revision, 1)
        self.store.comment(card["id"], "x")
        with open(path) as handle:
            stored = json.load(handle)["cards"][0]
        self.assertEqual((stored["type"], stored["priority"]), ("impl", "medium"))

    def test_mirror_shows_and_escapes(self):
        self.store.create_card("a", type="refactor", priority="low")
        card = self.store.create_card("arq", type="test")
        self.store.archive(card["id"])
        with open(os.path.join(self.dir, "BOARD.md")) as handle:
            text = handle.read()
        self.assertIn("tipo: refactor; prioridade: low", text)
        self.assertIn("tipo: test; prioridade: medium", text)
        self.assertEqual(store.md_escape("[bug](x)"), "\\[bug\\]\\(x\\)")

    def test_mirror_escapes_hand_edited_values(self):
        # values outside the lists read as the default, so nothing raw reaches the mirror
        self.store.create_card("a")
        path = os.path.join(self.dir, "board.json")
        with open(path) as handle:
            doc = json.load(handle)
        doc["cards"][0]["type"] = "# [x](http://y)"
        with open(path, "w") as handle:
            json.dump(doc, handle)
        self.store.create_card("b")
        with open(os.path.join(self.dir, "BOARD.md")) as handle:
            text = handle.read()
        self.assertNotIn("[x]", text)
        self.assertEqual(text.count("tipo: impl"), 2)
        rows = journal(self.store)
        self.assertEqual(rows[-1]["detail"]["type"], "impl")


V1_CARDS = [
    {"id": "aaaaaaa1", "title": "um", "body": "", "column": "todo", "labels": [],
     "assignee": "", "createdBy": "", "createdAt": "2026-11-01T00:00:00Z",
     "updatedAt": "2026-11-01T00:00:00Z", "archived": False, "comments": []},
    {"id": "aaaaaaa2", "title": "dois", "body": "b", "column": "doing", "labels": ["x"],
     "assignee": "ana", "createdBy": "ag", "createdAt": "2026-11-01T00:00:00Z",
     "updatedAt": "2026-11-01T00:00:00Z", "archived": False, "comments": []},
    {"id": "aaaaaaa3", "title": "três", "body": "", "column": "done", "labels": [],
     "assignee": "", "createdBy": "", "createdAt": "2026-11-01T00:00:00Z",
     "updatedAt": "2026-11-01T00:00:00Z", "archived": True, "comments": []},
]


class MigrationTests(StoreTestCase):
    def setUp(self):
        StoreTestCase.setUp(self)
        self.path = os.path.join(self.dir, "board.json")
        self.bak = os.path.join(self.dir, "board.json.v1.bak")

    def write_v1(self, schema=1, revision=7):
        doc = {"schema": schema, "revision": revision, "columns": store.DEFAULT_COLUMNS,
               "cards": V1_CARDS}
        raw = json.dumps(doc, ensure_ascii=False, indent=1).encode("utf-8")
        with open(self.path, "wb") as handle:
            handle.write(raw)
        return raw

    def read(self, path):
        with open(path, "rb") as handle:
            return handle.read()

    def test_migrates_once(self):
        raw = self.write_v1()
        fresh = Store(self.dir)
        board = fresh.board(include_archived=True)
        self.assertEqual(board["schema"], 2)
        self.assertEqual(len(board["cards"]), 3)
        self.assertTrue(all((c["type"], c["priority"]) == ("impl", "medium")
                            for c in board["cards"]))
        self.assertEqual([c["title"] for c in board["cards"]], ["um", "dois", "três"])
        stored = json.loads(self.read(self.path).decode("utf-8"))
        self.assertEqual(stored["schema"], 2)
        self.assertTrue(all((c["type"], c["priority"]) == ("impl", "medium")
                            for c in stored["cards"]))
        self.assertEqual(self.read(self.bak), raw)
        self.assertEqual(stat.S_IMODE(os.stat(self.bak).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(self.path).st_mode), 0o600)
        rows = journal(fresh)
        self.assertEqual([r["type"] for r in rows], ["migrate"])
        self.assertEqual(rows[0]["seq"], board["revision"])
        self.assertEqual(rows[0]["detail"], {"from": 1, "to": 2, "cards": 3})
        with open(os.path.join(self.dir, "BOARD.md")) as handle:
            mirror = handle.read()
        self.assertIn("Revisão %d" % board["revision"], mirror)
        self.assertIn("tipo: impl; prioridade: medium", mirror)
        self.assertEqual([x for x in os.listdir(self.dir) if x.startswith(".tmp-")], [])
        # opening again changes nothing
        after = self.read(self.path)
        rev = fresh.revision
        again = Store(self.dir)
        self.assertEqual(again.revision, rev)
        self.assertEqual(again.board(include_archived=True), board)
        self.assertEqual(self.read(self.path), after)
        self.assertEqual(self.read(self.bak), raw)
        self.assertEqual(len(journal(again)), 1)
        # the next change goes on from the migrated revision
        again.create_card("novo")
        self.assertEqual([e["seq"] for e in again.events()], [rev, rev + 1])

    def test_existing_backup_is_kept(self):
        with open(self.bak, "wb") as handle:
            handle.write(b"copia antiga")
        self.write_v1()
        self.assertEqual(Store(self.dir).board()["schema"], 2)
        self.assertEqual(self.read(self.bak), b"copia antiga")

    def test_board_without_schema_is_v1(self):
        doc = {"revision": 1, "columns": store.DEFAULT_COLUMNS, "cards": V1_CARDS[:1]}
        with open(self.path, "w") as handle:
            json.dump(doc, handle)
        self.assertEqual(Store(self.dir).card("aaaaaaa1")["type"], "impl")
        self.assertTrue(os.path.exists(self.bak))

    def test_newer_or_bad_schema_and_broken_json_untouched(self):
        cases = [self.write_v1(schema=3), self.write_v1(schema="2"), b'{"schema": 1, "revision']
        for raw in cases:
            with self.subTest(raw=raw[:40]):
                with open(self.path, "wb") as handle:
                    handle.write(raw)
                s = Store(self.dir)
                for call in (lambda: s.board(), lambda: s.revision, lambda: s.cards(),
                             lambda: s.create_card("a")):
                    with self.assertRaises(StoreCorrupt):
                        call()
                self.assertEqual(self.read(self.path), raw)
                self.assertFalse(os.path.exists(self.bak))
                self.assertFalse(os.path.exists(os.path.join(self.dir, "events.jsonl")))
                self.assertFalse(os.path.exists(os.path.join(self.dir, "BOARD.md")))

    def test_threads_migrate_once(self):
        self.write_v1()
        stores = [Store(self.dir) for _ in range(4)]
        threads = [threading.Thread(target=s.board) for s in stores]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual([r["type"] for r in journal(stores[0])], ["migrate"])
        self.assertEqual(stores[0].revision, 8)


if __name__ == "__main__":
    unittest.main()
