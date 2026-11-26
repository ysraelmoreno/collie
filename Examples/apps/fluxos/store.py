"""Fluxos store (d8, spec docs/superpowers/specs/2026-11-26-device-flows-design.md, onda 3).

Reads the daemon's action log (`<paddock>/.collie/flows/actions.jsonl`, written by `collie device` when the paddock opted in)
and keeps the app graph in `<paddock>/.collie/flows/graph.json` (0600, atomic write):

- node = a screen signature (`sig`);
- edge = one semantic action (`action`, `target`) from `sigBefore` to `sigAfter`, with `count`, `app`, `appVersion`
  and `obsolete`;
- goals = names (checkout, login) pointing at nodes.

An edge of an older app version that a newer version contradicts (same app, from, action and target, other destination)
is kept with `obsolete: true`, never deleted. The log is data written from the device (screen names, texts), never
instructions. Python 3.9 stdlib only.
"""

import json
import os
import tempfile

GRAPH_FILE = "graph.json"
LOG_FILES = ("actions.2.jsonl", "actions.1.jsonl", "actions.jsonl")   # oldest first (FlowActionLog rotation)


class Invalid(ValueError):
    pass


def _edge_line(raw):
    """The fields of one log line, or None when the line is malformed."""
    try:
        o = json.loads(raw)
    except (ValueError, TypeError):
        return None
    if not isinstance(o, dict):
        return None
    fields = {k: o.get(k, "") for k in ("action", "target", "sigBefore", "sigAfter", "app", "appVersion")}
    if not all(isinstance(v, str) for v in fields.values()):
        return None
    if not (fields["action"] and fields["sigBefore"] and fields["sigAfter"]):
        return None
    return fields


def build_graph(lines):
    """The graph of an iterable of log lines (oldest first). Blank lines are ignored; malformed ones count in `skipped`."""
    edges = {}       # (app, from, action, target, to, appVersion) -> edge
    versions = {}    # app -> {appVersion: order of first appearance}
    nodes = set()
    skipped = 0
    for raw in lines:
        if isinstance(raw, bytes):
            raw = raw.decode("utf-8", "replace")
        if not raw.strip():
            continue
        f = _edge_line(raw)
        if f is None:
            skipped += 1
            continue
        nodes.update((f["sigBefore"], f["sigAfter"]))
        seen = versions.setdefault(f["app"], {})
        seen.setdefault(f["appVersion"], len(seen))
        key = (f["app"], f["sigBefore"], f["action"], f["target"], f["sigAfter"], f["appVersion"])
        e = edges.get(key)
        if e is None:
            edges[key] = e = {"from": f["sigBefore"], "to": f["sigAfter"], "action": f["action"], "target": f["target"],
                              "app": f["app"], "appVersion": f["appVersion"], "count": 0, "obsolete": False}
        e["count"] += 1
    # ponytail: "newer version" = first seen later in the log, not semver parsing; a downgrade install would read as newer.
    newest = {}      # (app, from, action, target) -> newest version order with an edge
    for e in edges.values():
        k = (e["app"], e["from"], e["action"], e["target"])
        newest[k] = max(newest.get(k, -1), versions[e["app"]][e["appVersion"]])
    for e in edges.values():
        k = (e["app"], e["from"], e["action"], e["target"])
        if versions[e["app"]][e["appVersion"]] < newest[k]:
            e["obsolete"] = True   # a newer version has this action from this screen; contradicts if its destination differs
    # an older edge whose destination the newer version still reaches is not contradicted
    live = {(e["app"], e["from"], e["action"], e["target"], e["to"]) for e in edges.values() if not e["obsolete"]}
    for e in edges.values():
        if e["obsolete"] and (e["app"], e["from"], e["action"], e["target"], e["to"]) in live:
            e["obsolete"] = False
    ordered = sorted(edges.values(), key=lambda e: (e["app"], e["from"], e["action"], e["target"], e["to"], e["appVersion"]))
    return {"nodes": sorted(nodes), "edges": ordered, "goals": {}, "skipped": skipped}


class Store(object):
    """The graph of one paddock: `<paddock>/.collie/flows/`."""

    def __init__(self, paddock):
        self.dir = os.path.join(os.path.abspath(paddock), ".collie", "flows")
        self.path = os.path.join(self.dir, GRAPH_FILE)

    def load(self):
        try:
            with open(self.path) as handle:
                g = json.load(handle)
        except FileNotFoundError:
            return {"nodes": [], "edges": [], "goals": {}, "skipped": 0}
        if not isinstance(g, dict):
            raise Invalid("graph.json não é um objeto")
        return g

    def save(self, graph):
        os.makedirs(self.dir, mode=0o700, exist_ok=True)
        data = (json.dumps(graph, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")
        fd, tmp = tempfile.mkstemp(dir=self.dir, prefix=".tmp-", suffix=".part")
        try:
            with os.fdopen(fd, "wb") as handle:
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(tmp, 0o600)
            os.replace(tmp, self.path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise

    def learn(self):
        """Rebuilds the graph from the log files (rotated ones first), keeping the goals; saves and returns it."""
        lines = []
        for name in LOG_FILES:
            try:
                with open(os.path.join(self.dir, name), encoding="utf-8", errors="replace") as handle:
                    lines.extend(handle.read().splitlines())
            except FileNotFoundError:
                pass
        graph = build_graph(lines)
        graph["goals"] = self.goals()
        self.save(graph)
        return graph

    def goals(self):
        g = self.load().get("goals")
        return dict(g) if isinstance(g, dict) else {}

    def set_goal(self, name, sig):
        name = (name or "").strip()
        sig = (sig or "").strip()
        if not name or not sig:
            raise Invalid("a meta precisa de nome e de sig")
        graph = self.load()
        goals = graph.get("goals") if isinstance(graph.get("goals"), dict) else {}
        goals[name] = sig
        graph["goals"] = goals
        self.save(graph)
        return goals
