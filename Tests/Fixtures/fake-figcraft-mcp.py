#!/usr/bin/python3 -I
"""Fake `figcraft-cli mcp` for tests: minimal MCP over stdio, one JSON object per line.
Logs every request as `<method> <tool> <command>` to $ORQ_FAKE_FIG_LOG (initialize logs `initialize <client name>`).
ORQ_FAKE_FIG_SLEEP=<s> delays each tools/call answer. ORQ_FAKE_FIG_NOISE=1 sends garbage, a notification and an answer
with a foreign id before each answer. run_command ids: `bad.*` fails (isError, like the engine: "unknown command `bad.x`";
`bad.leak` also echoes a share link and the server key), `big` answers 17 MiB, `die` exits, `rpcerr` answers a JSON-RPC
error without a message, `slow` answers after 2 s, `file.save {path}` writes a stand-in file there. Each special id may also be prefixed with
`node.` (`node.die`, `node.bad.x`): an id Orq lets callers run.
A `batch` with a `node.big` step answers 17 MiB (its log line ends with its label). Each `collab.join` also logs `join <host of its link>`.
`library.publishToServer` answers the next version (1, 2, ...); with `server`, a copy's links and version 1. ORQ_FAKE_FIG_FLAGS=<dir>: while `<dir>/fail-<command id>`
exists that command fails (isError); with `<dir>/named-links`, each `variable.list` also logs
`variables <file name>`, and while `<dir>/black-dark@<file name>` exists that file's first variable is black in
its second mode; while `<dir>/white-bg` exists the first variable is white in its first mode; while `<dir>/slow-<command id>`
exists it answers after the seconds it holds; while `<dir>/fail-batch-<command id>` exists a batch with that step fails
(echoing the share link). `library.list {assets: true}` lists one library at the view link publishing the fixture's variables.
Each `library.bindVariable` step of a batch logs `bind <variable> <field> <ids>`.
The document is a list of node ids: each `node.create` in a successful `batch` adds one; a failed batch adds none.
Shared by every fake process of a test (in `state.json` next to the log): `node.set {characters}` sets the first text
of the fixture tree; `edit.delete {ids}` with the fixture root makes its `get_node` fail (`no such layer <id>`);
`node.slowreads` makes every later `get_node` sleep 30 s. `text.fonts` lists Inter; `{family: Inter}` its four styles."""
import base64, json, os, struct, sys, time, zlib

LOG = os.environ.get("ORQ_FAKE_FIG_LOG")


def log(*parts):
    if LOG:
        with open(LOG, "a") as f:
            f.write(" ".join(str(p) for p in parts) + "\n")


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def png(w, h):
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    raw = b"".join(b"\x00" + b"\xff\x00\x00" * w for _ in range(h))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def text(v, error=False):
    r = {"content": [{"type": "text", "text": v if isinstance(v, str) else json.dumps(v)}]}
    if error:
        r["isError"] = True
    return r


VERSION = [0]
LINK = "figcraft://join?host=127.0.0.1:47900&file=f1&token=fakeToken"
NODES = []
FILE = [""]   # the file this client published or joined (named links)
COMMANDS = {
    "collab.join": {"status": "live", "readOnly": False},
    "collab.publish": {"status": "connecting", "readOnly": True},
    "collab.peers": {"status": "live", "readOnly": False, "peers": [{"name": "agent"}], "link": LINK,
                     "published": {"edit": LINK, "view": LINK + "v", "file": "f1", "server": "127.0.0.1:47900"}},
    "inspect.code": {"code": "<div>Hello</div>"},
    "text.fonts": ["Inter"],
}


HTML_EXPORT = os.path.join(os.path.dirname(os.path.realpath(__file__)), "html-export")
ROOT_ID = 2   # the fixture's `Landing`


STATE = os.path.join(os.path.dirname(LOG), "state.json") if LOG else None


def state():
    try:
        with open(STATE) as f:
            return json.load(f)
    except (OSError, TypeError, ValueError):
        return {}


def save(**kv):
    if STATE:
        d = dict(state(), **kv)
        with open(STATE + ".tmp", "w") as f:
            json.dump(d, f)
        os.replace(STATE + ".tmp", STATE)


def first_text(n):
    if n.get("type") == "TEXT":
        return n
    for c in n.get("children", []):
        t = first_text(c)
        if t:
            return t
    return None


def fixture(name):
    with open(os.path.join(HTML_EXPORT, name)) as f:
        return f.read()


def tool(name, args):
    if name == "run_command":
        orig = cmd = args.get("command", "")
        if cmd.startswith("node.") and (cmd[5:] in ("die", "slow", "big") or cmd[5:].startswith("bad.")):
            cmd = cmd[5:]
        if cmd == "die":
            sys.exit(3)
        if cmd == "big":
            return text("x" * (17 << 20))
        if cmd == "slow":
            time.sleep(2)
        if cmd == "node.set" and "characters" in args.get("params", {}):
            save(characters=args["params"]["characters"])
        if cmd == "edit.delete" and ROOT_ID in [int(i) for i in str(args.get("params", {}).get("ids", "")).strip("[]").split(",") if i.strip()]:
            save(deleted=True)
        if cmd == "node.slowreads":
            save(slowreads=True)
        if cmd == "bad.leak":
            return text("cannot reach %s (ws://127.0.0.1:47900/?key=fakeKey_123-abc)" % LINK, error=True)
        if cmd.startswith("bad."):
            return text("unknown command `%s`" % orig, error=True)
        flags = os.environ.get("ORQ_FAKE_FIG_FLAGS")
        named = flags and os.path.exists(os.path.join(flags, "named-links"))
        if named and cmd == "collab.publish":
            FILE[0] = args.get("params", {}).get("name", "")
        if named and cmd == "collab.join":
            FILE[0] = args.get("params", {}).get("link", "").split("&n=", 1)[-1] if "&n=" in args.get("params", {}).get("link", "") else ""
        if named and FILE[0] and os.path.exists(os.path.join(flags, "fail-%s@%s" % (cmd, FILE[0]))):
            return text("command `%s` failed (fake)" % cmd, error=True)
        if named and cmd == "collab.peers" and FILE[0]:
            r = json.loads(json.dumps(COMMANDS[cmd]))
            r["published"]["edit"] += "&n=" + FILE[0]
            r["published"]["view"] = LINK + "&n=" + FILE[0] + "v"
            return text(r)
        if flags and os.path.exists(os.path.join(flags, "slow-" + cmd)):
            time.sleep(float(open(os.path.join(flags, "slow-" + cmd)).read() or "1"))
        if flags and os.path.exists(os.path.join(flags, "fail-" + cmd)):
            return text("command `%s` failed (fake)" % cmd, error=True)
        if cmd == "text.fonts" and args.get("params", {}).get("family"):
            return text(["Regular", "Italic", "SemiBold", "Bold"] if args["params"]["family"] == "Inter" else [])
        if cmd == "library.publishToServer":
            VERSION[0] += 1
            r = {"id": "lib1", "version": VERSION[0], "variables": 14}
            if args.get("params", {}).get("server"):   # a copy kept as a new file: its own library, links
                VERSION[0] -= 1
                r = {"id": "lib2", "version": 1, "file": "f2", "edit": LINK.replace("f1", "f2"), "view": LINK.replace("f1", "f2") + "v"}
            return text(r)
        if cmd == "library.list" and args.get("params", {}).get("assets"):
            vs = json.loads(fixture("variables.json"))["variables"]
            return text({"libraries": [{"id": "lib1", "name": "fake", "path": LINK + "v", "server": True,
                                        "variables": [{"id": v["id"], "name": v["name"]} for v in vs]}]})
        if cmd == "inspect.code" and args.get("params", {}).get("id") == ROOT_ID:
            return text({"code": fixture("code.html") + "<!-- " + LINK + " -->"})
        if named and cmd == "variable.list":
            log("variables", FILE[0])
        if cmd in ("variable.list", "inspect.assets", "file.exportLayers"):
            out = fixture({"variable.list": "variables.json", "inspect.assets": "assets.json",
                                 "file.exportLayers": "export-files.json"}[cmd])
            # a planted secret in the answers of the fixture root: callers must get it scrubbed
            if cmd == "variable.list":
                d = json.loads(out)
                if named and FILE[0] and os.path.exists(os.path.join(flags, "black-dark@" + FILE[0])):
                    d["variables"][0]["values"]["VariableCollectionId:1/mode2"]["value"] = {"r": 0, "g": 0, "b": 0, "a": 1}
                if flags and os.path.exists(os.path.join(flags, "white-bg")):
                    d["variables"][0]["values"]["VariableCollectionId:1/mode1"]["value"] = {"r": 1, "g": 1, "b": 1, "a": 1}
                out = json.dumps(dict(d, note=LINK))
            if cmd == "file.exportLayers":   # the icon's SVG text too
                d = json.loads(out)
                for f in d["files"]:
                    if f["id"] == 18:
                        f["data"] = base64.b64encode(base64.b64decode(f["data"]) + ("<!-- %s -->" % LINK).encode()).decode()
                out = json.dumps(d)
            if cmd == "inspect.assets":
                d = json.loads(out)
                d["assets"][0]["name"] += " " + LINK
                out = json.dumps(d)
            return text(out)
        if cmd == "file.save":
            path = args.get("params", {}).get("path", "")
            with open(path, "wb") as f:
                f.write(b"PK fake figcraft")
            return text({"path": path, "bytes": 16})
        return text(COMMANDS.get(cmd, {"ok": True, "command": cmd, "params": args.get("params", {})}))
    if name == "batch":
        cmds = args.get("commands", [])
        flags = os.environ.get("ORQ_FAKE_FIG_FLAGS")
        for c in cmds:
            if flags and os.path.exists(os.path.join(flags, "fail-batch-%s" % c.get("command"))):
                return text("command `%s` failed (fake) at %s" % (c["command"], LINK), error=True)
            if c.get("command") == "library.bindVariable":
                p = c.get("params", {})
                log("bind", p.get("variable"), p.get("field"), json.dumps(p.get("ids")))
            if c.get("command") == "node.big":
                return text("x" * (17 << 20))
            if "bad." in str(c.get("command", "")):
                return text("unknown command `%s`" % c["command"], error=True)
        out = []
        for c in cmds:
            if c.get("command") == "node.create":
                NODES.append(4294967296 + len(NODES) + 1)
                save(nodes=sorted(set(state().get("nodes", []) + NODES)))   # one live document: other clients see it
                out.append({"id": NODES[-1]})
            else:
                out.append({"ok": True})
        return text(out)
    if name == "list_commands":
        return text("5 commands (id \u2014 label [menu] (shortcut) params; * = undoable):\n"
                    "node.create* \u2014 Create layer [Insert] {type, parent?}\n"
                    "align.left* \u2014 Align left [Arrange] (Alt+A) {ids?}\n  second line of align docs\n"
                    "collab.join \u2014 Join a live session {link}\n"
                    "file.open \u2014 Open [File] {path}\n"
                    "plugin.run \u2014 Run plugin {id}\n")
    st = state() if name == "get_node" else {}
    if st.get("slowreads"):
        time.sleep(30)
    if name == "get_node" and args.get("id") == ROOT_ID and st.get("deleted"):
        return text("no such layer %d" % ROOT_ID, error=True)
    if name == "get_node" and args.get("id") == ROOT_ID:
        tree = json.loads(fixture("node.json"))
        if "characters" in st:
            first_text(tree)["characters"] = st["characters"]
        return text(dict(tree, note=LINK))
    if name == "get_node":
        return text({"id": args.get("id"), "type": "FRAME", "children": []})
    if name == "inspect_document":
        nodes = sorted(set(state().get("nodes", []) + NODES))
        return text({"pages": [{"id": 1, "name": "Page 1", "children": [{"id": n, "type": "FRAME"} for n in nodes]}]})
    if name == "screenshot":
        return {"content": [{"type": "image", "mimeType": "image/png", "data": base64.b64encode(png(4, 8)).decode()}]}
    return text("unknown tool " + name, error=True)


for line in sys.stdin:
    try:
        msg = json.loads(line)
    except ValueError:
        continue
    method, mid = msg.get("method"), msg.get("id")
    if method == "initialize":
        log("initialize", msg["params"]["clientInfo"]["name"])
        send({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                                                      "serverInfo": {"name": "fake-figcraft", "version": "0"}}})
    elif method == "tools/call":
        p = msg.get("params", {})
        log("tools/call", p.get("name"), p.get("arguments", {}).get("command", "") or p.get("arguments", {}).get("label", ""))
        if p.get("arguments", {}).get("command") == "collab.join":
            link = p["arguments"].get("params", {}).get("link", "")
            log("join", link.split("host=", 1)[-1].split("&", 1)[0])
        if p.get("arguments", {}).get("command") == "rpcerr":
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32603}})
            continue
        if os.environ.get("ORQ_FAKE_FIG_SLEEP"):
            time.sleep(float(os.environ["ORQ_FAKE_FIG_SLEEP"]))
        result = tool(p.get("name"), p.get("arguments", {}))
        if os.environ.get("ORQ_FAKE_FIG_NOISE"):
            sys.stdout.write("not json at all\n")
            send({"jsonrpc": "2.0", "method": "notifications/message", "params": {"level": "info", "data": "hi"}})
            send({"jsonrpc": "2.0", "id": 987654, "result": text({"wrong": True})})
        send({"jsonrpc": "2.0", "id": mid, "result": result})
    elif method is not None:
        log(method)
        if mid is not None:
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "no method " + method}})
