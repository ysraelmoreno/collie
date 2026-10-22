"""Minimal stdio MCP client for figcraft-cli mcp (spike only)."""
import json, subprocess, sys, base64

class Mcp:
    def __init__(self, cli, *args, name="agent"):
        self.p = subprocess.Popen([cli, "mcp", *args], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=open(f"/dev/null", "w"), text=True, bufsize=1)
        self.n = 0
        self.name = name
        self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                "clientInfo": {"name": name, "version": "0"}})
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")

    def rpc(self, method, params):
        self.n += 1
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params}) + "\n")
        self.p.stdin.flush()
        while True:
            line = self.p.stdout.readline()
            if not line:
                raise RuntimeError("mcp closed")
            msg = json.loads(line)
            if msg.get("id") == self.n:
                if "error" in msg:
                    raise RuntimeError(f"{method}: {msg['error']}")
                return msg["result"]

    def tool(self, name, args=None, raw=False):
        r = self.rpc("tools/call", {"name": name, "arguments": args or {}})
        if raw:
            return r
        texts = [c["text"] for c in r.get("content", []) if c.get("type") == "text"]
        if r.get("isError"):
            raise RuntimeError(f"{name} {json.dumps(args)[:300]}: {' '.join(texts)[:600]}")
        t = "\n".join(texts)
        try:
            return json.loads(t)
        except Exception:
            return t

    def cmd(self, command, params=None):
        return self.tool("run_command", {"command": command, "params": params or {}})

    def image(self, name, args, path):
        r = self.tool(name, args, raw=True)
        for c in r.get("content", []):
            if c.get("type") == "image":
                open(path, "wb").write(base64.b64decode(c["data"]))
                return path
        raise RuntimeError(f"no image: {json.dumps(r)[:400]}")

    def close(self):
        self.p.stdin.close()
        self.p.wait(timeout=10)
