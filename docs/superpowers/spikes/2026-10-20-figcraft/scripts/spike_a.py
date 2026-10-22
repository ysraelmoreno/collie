"""Path (a) proof: agent (headless MCP) builds portfolio on a figcraft-server file; a second client
(standing in for the UI) joins the same session and sees/edits the same live document."""
import json, sys, time, os
sys.path.insert(0, os.path.dirname(__file__))
from mcp import Mcp
import portfolio

S = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLI = f"{S}/target/release/figcraft-cli"
OUT = f"{S}/portfolio"
KEY = open(f"{S}/srvdata/server.key").read().strip()
log = open(f"{S}/spike_a.log", "w")

def say(*a):
    s = " ".join(str(x) for x in a)
    print(s); log.write(s + "\n"); log.flush()

def wait_live(m, label):
    for _ in range(100):
        p = m.cmd("collab.peers")
        if p.get("status") == "live" and p.get("syncing", True) and not p.get("readOnly"):
            return p
        if p.get("status") == "failed":
            raise RuntimeError(f"{label}: {p.get('reason')}")
        time.sleep(0.2)
    raise RuntimeError(f"{label}: not live: {p}")

agent = Mcp(CLI, "--automation-read-root", S, "--automation-write-root", OUT, name="agent")
# 1) publish an empty doc to the server; the agent is now a live client of that file
agent.cmd("collab.publish", {"server": f"ws://127.0.0.1:47900/?key={KEY}", "name": "portfolio"})
p = wait_live(agent, "agent publish")
pub = p["published"]
say("published file:", pub["file"], "status:", p["status"], "role:", p["role"])
edit_link = pub["edit"]
open(f"{S}/.edit_link", "w").write(edit_link)  # local only, for the UI join

# 2) a second client (the "UI" stand-in) joins the same file BEFORE the agent builds
ui = Mcp(CLI, name="ui")
ui.cmd("collab.join", {"link": edit_link})
pu = wait_live(ui, "ui join")
say("ui joined:", pu["status"], "peers seen by ui:", [x["name"] for x in pu.get("peers", [])])

# 3) agent builds tokens (variables w/ Light+Dark) and the portfolio as ONE batch = one undo step
ids = portfolio.setup_tokens(agent)
cmds, root_ref = portfolio.build(ids)
t0 = time.time()
r = agent.tool("batch", {"commands": cmds, "label": "Import portfolio"})
say(f"batch of {len(cmds)} commands ok in {time.time()-t0:.2f}s")
results = r.get("results", r) if isinstance(r, dict) else r
root = results[0]["id"] if isinstance(results, list) else None
say("root id:", root)

# 4) the UI client sees the same nodes (state arrives over the session)
def count(m):
    d = m.tool("inspect_document", {"depth": 99})
    s = json.dumps(d)
    return s.count('"type": "TEXT"') + s.count('"type":"TEXT"') + s.count('"kind": "text"'), len(s), d
ua = None
for i in range(100):
    try:
        ui.cmd("collab.peers"); ua = ui.tool("get_node", {"id": root, "depth": 1}); break
    except RuntimeError as e:
        last_err = str(e)[:200]
        time.sleep(0.1)
else:
    say("ui get_node kept failing:", last_err)
say(f"ui saw root after ~{i*0.1:.1f}s polling")
say("ui sees root:", json.dumps(ua)[:200])

# 5) UI-side edit -> agent sees it
ui.tool("set_properties", {"ids": [root], "props": {"name": "Portfolio (renamed by UI)"}})
for _ in range(50):
    agent.cmd("collab.peers"); n = agent.tool("get_node", {"id": root, "depth": 0})
    if "renamed by UI" in json.dumps(n):
        break
    time.sleep(0.2)
say("agent name seen:", n.get("name") if isinstance(n, dict) else n, "| agent session:", json.dumps({k: agent.cmd('collab.peers').get(k) for k in ('status','document','syncing','readOnly')}))
say("agent sees UI rename:", "renamed by UI" in json.dumps(n))

# 6) agent-side edit -> UI sees it (switch to Dark mode)
agent.cmd("variable.setMode", {"ids": [root], "collection": ids["_collection"], "mode": "Dark"})
time.sleep(1)
ui.cmd("collab.peers"); nu = ui.tool("get_node", {"id": root, "depth": 0})
say("ui root after agent setMode Dark:", json.dumps(nu)[:400])
ui.cmd("collab.peers"); ui.image("screenshot", {"ids": [root], "scale": 1, "maxSize": 2400}, f"{OUT}/portfolio-dark-from-ui-client.png")
agent.cmd("variable.setMode", {"ids": [root], "collection": ids["_collection"], "mode": "Light"})
time.sleep(1)
ui.cmd("collab.peers"); ui.image("screenshot", {"ids": [root], "scale": 1, "maxSize": 2400}, f"{OUT}/portfolio-light-from-ui-client.png")

# 7) undo: the batch is one undo step for the agent
peers = agent.cmd("collab.peers")
say("agent peers:", [x["name"] for x in peers.get("peers", [])])

ui.cmd("collab.peers")
# 8) export from the live doc (taken from the UI client's copy to prove it is the same doc)
for lang in ("html", "css", "react"):
    c = ui.cmd("inspect.code", {"id": root, "language": lang})
    ext = {"html": "html", "css": "css", "react": "tsx"}[lang]
    open(f"{OUT}/export-{lang}.{ext}", "w").write(c["code"])
    say(f"export {lang}: {len(c['code'])} bytes")
agent.tool("save_file", {"path": f"{OUT}/portfolio.figcraft"})
say("saved", f"{OUT}/portfolio.figcraft")
json.dump({"root": root, "vars": ids}, open(f"{S}/.ids.json", "w"))

if "--keep" in sys.argv:
    say("keeping agent alive for UI join; press enter")
    input()
ui.close(); agent.close()
