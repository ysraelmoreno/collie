#!/usr/bin/env python3
"""Probe for the Collie device helper: python3 helper-probe.py [serial]. Measures dump and tap and prints a summary.
Needs `adb forward tcp:7790 localabstract:collie-helper` (done here).
For stress-toggle.sh, on a port already forwarded: `--nodes PORT` prints the node count of one dump (0 when the helper
does not answer); `--wait PORT [SECS=5]` dumps every 300 ms and prints the ms until a dump has nodes (-1 if none in SECS)."""
import json, os, socket, subprocess, sys, time
def nodes(port):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=2) as c:
            c.settimeout(2); f = c.makefile("rwb"); f.write(b'{"op":"dump","id":1}\n'); f.flush()
            return len(json.loads(f.readline() or b"{}").get("nodes", []))
    except (OSError, ValueError):
        return 0
if len(sys.argv) > 2 and sys.argv[1] == "--nodes":
    print(nodes(int(sys.argv[2]))); sys.exit(0)
if len(sys.argv) > 2 and sys.argv[1] == "--wait":
    t0 = time.time(); limit = float(sys.argv[3]) if len(sys.argv) > 3 else 5.0
    while time.time() - t0 < limit:
        if nodes(int(sys.argv[2])) > 0: print(int((time.time() - t0) * 1000)); sys.exit(0)
        time.sleep(0.3)
    print(-1); sys.exit(0)
A = os.path.expanduser("~/Library/Android/sdk/platform-tools/adb"); SER = sys.argv[1] if len(sys.argv) > 1 else "emulator-5554"
subprocess.run([A, "-s", SER, "forward", "tcp:7790", "localabstract:collie-helper"], check=True)
s = socket.create_connection(("127.0.0.1", 7790), timeout=10); f = s.makefile("rwb"); n = 0
def call(**req):
    global n; n += 1; req["id"] = n; t0 = time.time(); f.write((json.dumps(req) + "\n").encode()); f.flush()
    line = f.readline()
    if not line: raise SystemExit("connection closed (uid refused, or the helper is not enabled)")
    return json.loads(line), int((time.time() - t0) * 1000)
r, ms = call(op="hello"); print("hello", r, f"{ms} ms")
for i in range(5):
    r, ms = call(op="dump"); nodes = r.get("nodes", [])
    print(f"dump {i}: {ms} ms, {len(nodes)} nodes, labeled={sum(1 for x in nodes if x['text'] or x['desc'])}")
print("labels:", [x["text"] or x["desc"] for x in nodes if x["text"] or x["desc"]][:10])
r, ms = call(op="global", action="back"); print("back", r, f"{ms} ms")
