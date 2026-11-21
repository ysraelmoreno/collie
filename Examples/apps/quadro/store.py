"""Quadro storage: board.json is the truth, BOARD.md a readable mirror,
events.jsonl an append-only journal.

Python 3.9, standard library only.

Every change takes the thread lock and the process lock (flock on
board.lock), reads board.json from disk, applies the change, writes
board.json once (atomically), then appends the event, then regenerates
the mirror. Journal or mirror failures never fail the change.
"""

import copy
import datetime
import fcntl
import json
import os
import re
import tempfile
import threading
import uuid
from contextlib import contextmanager

SCHEMA = 1
JOURNAL_LIMIT = 5 * 1024 * 1024
EVENTS_PAGE = 200

MAX_TITLE = 200
MAX_BODY = 8000
MAX_COMMENT = 2000
MAX_COMMENTS = 200
MAX_LABELS = 10
MAX_LABEL = 32
MAX_ASSIGNEE = 64
MAX_BY = 64
MAX_CARDS = 2000

DEFAULT_COLUMNS = [
    {"id": "todo", "name": "A fazer"},
    {"id": "doing", "name": "Em andamento"},
    {"id": "review", "name": "Em revisão"},
    {"id": "done", "name": "Feito"},
]

UPDATABLE = ("title", "body", "labels", "assignee")

_CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f]")


class StoreError(Exception):
    """Base of the store's errors; the message is short and safe to show."""


class NotFound(StoreError):
    pass


class Invalid(StoreError):
    pass


class StoreCorrupt(StoreError):
    pass


def default_dir():
    env = os.environ.get("QUADRO_DIR")
    if env:
        return env
    return os.path.join(os.path.expanduser("~"), ".collie", "quadro")


def _utc_now():
    return datetime.datetime.now(datetime.timezone.utc)


def _iso(moment):
    return moment.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _new_id():
    return uuid.uuid4().hex[:8]


def clean_by(by):
    """`by` is free text from the caller: data, never identity."""
    if by is None:
        return ""
    if not isinstance(by, str):
        raise Invalid("by must be text")
    by = _CONTROL.sub("", by).strip()
    if len(by) > MAX_BY:
        raise Invalid("by too long (max %d)" % MAX_BY)
    return by


def _text(value, name, low, high):
    if not isinstance(value, str):
        raise Invalid("%s must be text" % name)
    if low > 0 and not value.strip():
        raise Invalid("%s is required" % name)
    if len(value) > high:
        raise Invalid("%s too long (max %d)" % (name, high))
    return value


def _labels(value):
    if isinstance(value, str) or not isinstance(value, (list, tuple)):
        raise Invalid("labels must be a list")
    if len(value) > MAX_LABELS:
        raise Invalid("too many labels (max %d)" % MAX_LABELS)
    out = []
    for label in value:
        if not isinstance(label, str) or not label.strip():
            raise Invalid("label must be non-empty text")
        if len(label) > MAX_LABEL:
            raise Invalid("label too long (max %d)" % MAX_LABEL)
        if label not in out:
            out.append(label)
    return out


def _card_id(value):
    if not isinstance(value, str) or not value:
        raise Invalid("id must be text")
    return value


_MD_SPECIAL = re.compile(r"([!-/:-@\[-`{-~])")


def md_escape(text):
    """Make agent text inert in Markdown: one line, every ASCII punctuation
    backslash-escaped (no heading, list, link, code, HTML or autolink)."""
    text = "" if text is None else str(text)
    text = _CONTROL.sub(" ", text)
    text = re.sub(r"\s+", " ", text).strip()
    return _MD_SPECIAL.sub(r"\\\1", text)


class Store(object):
    def __init__(self, dir=None, journal_limit=JOURNAL_LIMIT, clock=None):
        self.dir = os.path.abspath(dir or default_dir())
        self.journal_limit = journal_limit
        self._clock = clock or _utc_now
        self._rlock = threading.RLock()
        self._depth = 0
        self._lock_fd = None
        os.makedirs(self.dir, mode=0o700, exist_ok=True)
        os.chmod(self.dir, 0o700)
        self.board_path = os.path.join(self.dir, "board.json")
        self.mirror_path = os.path.join(self.dir, "BOARD.md")
        self.journal_path = os.path.join(self.dir, "events.jsonl")
        self.journal_old_path = os.path.join(self.dir, "events.1.jsonl")
        self.lock_path = os.path.join(self.dir, "board.lock")

    # ---- locking -------------------------------------------------------

    @contextmanager
    def _locked(self):
        with self._rlock:
            if self._depth == 0:
                fd = os.open(self.lock_path, os.O_RDWR | os.O_CREAT, 0o600)
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX)
                except BaseException:
                    os.close(fd)
                    raise
                self._lock_fd = fd
            self._depth += 1
            try:
                yield
            finally:
                self._depth -= 1
                if self._depth == 0:
                    fd, self._lock_fd = self._lock_fd, None
                    try:
                        fcntl.flock(fd, fcntl.LOCK_UN)
                    finally:
                        os.close(fd)

    # ---- files ---------------------------------------------------------

    def _load(self):
        try:
            with open(self.board_path, "rb") as handle:
                raw = handle.read()
        except FileNotFoundError:
            return {"schema": SCHEMA, "revision": 0,
                    "columns": copy.deepcopy(DEFAULT_COLUMNS), "cards": []}
        try:
            doc = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            raise StoreCorrupt("board.json does not decode")
        if (not isinstance(doc, dict)
                or not isinstance(doc.get("revision"), int)
                or not isinstance(doc.get("columns"), list)
                or not isinstance(doc.get("cards"), list)
                or not all(isinstance(c, dict) and isinstance(c.get("id"), str)
                           for c in doc["columns"])
                or not all(isinstance(c, dict) and isinstance(c.get("id"), str)
                           for c in doc["cards"])):
            raise StoreCorrupt("board.json has an unexpected shape")
        return doc

    def _atomic_write(self, path, data):
        fd, tmp = tempfile.mkstemp(dir=self.dir, prefix=".tmp-", suffix=".part")
        try:
            with os.fdopen(fd, "wb") as handle:
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(tmp, 0o600)
            os.replace(tmp, path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
        try:
            dfd = os.open(self.dir, os.O_RDONLY)
            try:
                os.fsync(dfd)
            finally:
                os.close(dfd)
        except OSError:
            pass

    def _append_event(self, event):
        line = (json.dumps(event, ensure_ascii=False, sort_keys=True) + "\n").encode("utf-8")
        try:
            size = os.path.getsize(self.journal_path)
        except FileNotFoundError:
            size = 0
        if size > 0 and size + len(line) > self.journal_limit:
            os.replace(self.journal_path, self.journal_old_path)
        fd = os.open(self.journal_path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            os.write(fd, line)
            os.fsync(fd)
        finally:
            os.close(fd)

    def _write_mirror(self, doc):
        self._atomic_write(self.mirror_path, render_markdown(doc).encode("utf-8"))

    # ---- change pipeline -----------------------------------------------

    def _mutate(self, change, by):
        """`change(doc, now)` edits doc in place and returns (result, event)
        or (result, None) when nothing changed."""
        by = clean_by(by)
        with self._locked():
            doc = self._load()
            now = _iso(self._clock())
            result, event = change(doc, now)
            if event is None:
                return copy.deepcopy(result)
            doc["schema"] = doc.get("schema", SCHEMA)
            doc["revision"] = doc["revision"] + 1
            data = json.dumps(doc, ensure_ascii=False, indent=1).encode("utf-8")
            self._atomic_write(self.board_path, data)
            record = {"seq": doc["revision"], "at": now, "by": by,
                      "type": event[0], "card": event[1], "detail": event[2]}
            try:
                self._append_event(record)
            except Exception:
                pass
            try:
                self._write_mirror(doc)
            except Exception:
                pass
            return copy.deepcopy(result)

    @staticmethod
    def _find(doc, card_id):
        card_id = _card_id(card_id)
        for card in doc["cards"]:
            if card.get("id") == card_id:
                return card
        raise NotFound("card not found")

    @staticmethod
    def _column(doc, column):
        if not isinstance(column, str) or column not in [c["id"] for c in doc["columns"]]:
            raise Invalid("unknown column")
        return column

    # ---- reads ---------------------------------------------------------

    @property
    def revision(self):
        with self._locked():
            return self._load()["revision"]

    def board(self, include_archived=False):
        with self._locked():
            doc = self._load()
        if not include_archived:
            doc["cards"] = [c for c in doc["cards"] if not c.get("archived")]
        return doc

    def cards(self, column=None, label=None, assignee=None, q=None):
        with self._locked():
            doc = self._load()
        needle = q.casefold() if q else None
        out = []
        for card in doc["cards"]:
            if card.get("archived"):
                continue
            if column and card.get("column") != column:
                continue
            if label and label not in card.get("labels", []):
                continue
            if assignee and card.get("assignee") != assignee:
                continue
            if needle is not None:
                hay = [card.get("title", ""), card.get("body", "")]
                hay += card.get("labels", [])
                hay += [c.get("text", "") for c in card.get("comments", [])]
                if not any(needle in str(h).casefold() for h in hay):
                    continue
            out.append(card)
        return out

    def card(self, id):
        with self._locked():
            doc = self._load()
        return self._find(doc, id)

    def events(self, since=0, limit=EVENTS_PAGE):
        if not isinstance(since, int) or isinstance(since, bool) or since < 0:
            raise Invalid("since must be a non-negative integer")
        if not isinstance(limit, int) or isinstance(limit, bool) or limit < 1:
            raise Invalid("limit must be a positive integer")
        limit = min(limit, EVENTS_PAGE)
        out = []
        with self._locked():
            for path in (self.journal_old_path, self.journal_path):
                try:
                    with open(path, "rb") as handle:
                        lines = handle.read().splitlines()
                except FileNotFoundError:
                    continue
                for line in lines:
                    try:
                        event = json.loads(line.decode("utf-8"))
                    except (UnicodeDecodeError, ValueError):
                        continue
                    if isinstance(event, dict) and isinstance(event.get("seq"), int) \
                            and event["seq"] > since:
                        out.append(event)
        out.sort(key=lambda e: e["seq"])
        return out[:limit]

    # ---- writes --------------------------------------------------------

    def create_card(self, title, body="", column="todo", labels=(), assignee="", by=""):
        title = _text(title, "title", 1, MAX_TITLE)
        body = _text(body, "body", 0, MAX_BODY)
        labels = _labels(labels)
        assignee = _text(assignee, "assignee", 0, MAX_ASSIGNEE)
        who = clean_by(by)

        def change(doc, now):
            self._column(doc, column)
            if len(doc["cards"]) >= MAX_CARDS:
                raise Invalid("too many cards (max %d)" % MAX_CARDS)
            taken = {c["id"] for c in doc["cards"]}
            card_id = _new_id()
            while card_id in taken:
                card_id = _new_id()
            card = {"id": card_id, "title": title, "body": body, "column": column,
                    "labels": labels, "assignee": assignee, "createdBy": who,
                    "createdAt": now, "updatedAt": now, "archived": False,
                    "comments": []}
            doc["cards"].append(card)
            return card, ("card.create", card_id, {"title": title, "column": column})

        return self._mutate(change, who)

    def update_card(self, id, by="", **fields):
        unknown = [k for k in fields if k not in UPDATABLE]
        if unknown:
            raise Invalid("unknown field: %s" % sorted(unknown)[0])
        checked = {}
        if "title" in fields:
            checked["title"] = _text(fields["title"], "title", 1, MAX_TITLE)
        if "body" in fields:
            checked["body"] = _text(fields["body"], "body", 0, MAX_BODY)
        if "labels" in fields:
            checked["labels"] = _labels(fields["labels"])
        if "assignee" in fields:
            checked["assignee"] = _text(fields["assignee"], "assignee", 0, MAX_ASSIGNEE)

        def change(doc, now):
            card = self._find(doc, id)
            changed = sorted(k for k, v in checked.items() if card.get(k) != v)
            if not changed:
                return card, None
            for key in changed:
                card[key] = checked[key]
            card["updatedAt"] = now
            return card, ("card.update", card["id"], {"fields": changed})

        return self._mutate(change, by)

    def move_card(self, id, column, index=None, by=""):
        if index is not None and (not isinstance(index, int) or isinstance(index, bool)
                                  or index < 0):
            raise Invalid("index must be a non-negative integer")

        def change(doc, now):
            card = self._find(doc, id)
            self._column(doc, column)
            cards = doc["cards"]
            before = [c["id"] for c in cards]
            source = card.get("column")
            cards.remove(card)
            peers = [i for i, c in enumerate(cards)
                     if c.get("column") == column and not c.get("archived")]
            if index is None or index >= len(peers):
                pos = (peers[-1] + 1) if peers else len(cards)
            else:
                pos = peers[index]
            cards.insert(pos, card)
            if source == column and [c["id"] for c in cards] == before:
                return card, None
            card["column"] = column
            card["updatedAt"] = now
            final = [c["id"] for c in cards
                     if c.get("column") == column and not c.get("archived")]
            at = final.index(card["id"]) if card["id"] in final else len(final)
            return card, ("card.move", card["id"],
                          {"from": source, "to": column, "index": at})

        return self._mutate(change, by)

    def comment(self, id, text, by=""):
        text = _text(text, "comment", 1, MAX_COMMENT)
        who = clean_by(by)

        def change(doc, now):
            card = self._find(doc, id)
            comments = card.setdefault("comments", [])
            if len(comments) >= MAX_COMMENTS:
                raise Invalid("too many comments (max %d)" % MAX_COMMENTS)
            entry = {"id": _new_id(), "by": who, "at": now, "text": text}
            comments.append(entry)
            card["updatedAt"] = now
            return card, ("card.comment", card["id"], {"comment": entry["id"]})

        return self._mutate(change, who)

    def _set_archived(self, id, value, by):
        def change(doc, now):
            card = self._find(doc, id)
            if bool(card.get("archived")) == value:
                return card, None
            card["archived"] = value
            card["updatedAt"] = now
            return card, ("card.archive" if value else "card.restore", card["id"], {})

        return self._mutate(change, by)

    def archive(self, id, by=""):
        return self._set_archived(id, True, by)

    def restore(self, id, by=""):
        return self._set_archived(id, False, by)


def render_markdown(doc):
    lines = ["# Quadro", "", "Revisão %d" % doc.get("revision", 0), ""]
    for column in doc.get("columns", []):
        col_id = column.get("id")
        cards = [c for c in doc.get("cards", [])
                 if c.get("column") == col_id and not c.get("archived")]
        lines.append("## %s (%d)" % (md_escape(column.get("name") or col_id), len(cards)))
        lines.append("")
        if not cards:
            lines.append("_vazio_")
        for card in cards:
            meta = [md_escape(card.get("id"))]
            if card.get("assignee"):
                meta.append("responsável: " + md_escape(card["assignee"]))
            if card.get("labels"):
                meta.append("rótulos: " + ", ".join(md_escape(l) for l in card["labels"]))
            if card.get("createdBy"):
                meta.append("por: " + md_escape(card["createdBy"]))
            lines.append("- %s (%s)" % (md_escape(card.get("title")), "; ".join(meta)))
            if card.get("body"):
                lines.append("    " + md_escape(card["body"]))
            for comment in card.get("comments", []):
                lines.append("    - %s, %s: %s" % (md_escape(comment.get("by") or "anônimo"),
                                                   md_escape(comment.get("at")),
                                                   md_escape(comment.get("text"))))
        lines.append("")
    archived = [c for c in doc.get("cards", []) if c.get("archived")]
    if archived:
        lines.append("## Arquivados (%d)" % len(archived))
        lines.append("")
        for card in archived:
            lines.append("- %s (%s)" % (md_escape(card.get("title")), md_escape(card.get("id"))))
        lines.append("")
    return "\n".join(lines)
