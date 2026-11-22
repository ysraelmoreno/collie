#!/usr/bin/env python3
"""Probe for the Collie device helper: python3 helper-probe.py [serial]. Measures dump and tap and prints a summary.
Needs `adb forward tcp:7790 localabstract:collie-helper` (done here)."""
import json, os, socket, subprocess, sys, time
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
