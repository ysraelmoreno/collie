#!/bin/bash
# Re-captures Tests/Fixtures/html-export/* from the real figcraft engine (vendor/figcraft, built by
# scripts/build-figcraft.sh): runs doc.json, opens the result over MCP and records the engine's answers.
set -euo pipefail
cd "$(dirname "$0")/.."
CLI="$PWD/vendor/figcraft/bin/figcraft-cli"
FX="$PWD/Tests/Fixtures/html-export"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# 2x2 RGB PNG for the Photo layer.
python3 -I - "$TMP/pixel.png" <<'PY'
import sys, zlib, struct
def chunk(t, d): c = struct.pack(">I", len(d)) + t + d; return c + struct.pack(">I", zlib.crc32(t + d))
raw = b"".join(b"\x00" + bytes([255, 0, 0, 0, 255, 0]) for _ in range(2))
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 2, 0, 0, 0))
                              + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
PY
sed "s#@PIXEL@#$TMP/pixel.png#" "$FX/doc.json" > "$TMP/doc.json"
"$CLI" run "$TMP/doc.json" --no-system-fonts --out "$TMP/doc.figcraft" > "$TMP/run.out"
ROOT="$(python3 -I - "$TMP/run.out" <<'PY'
import sys, json
for l in open(sys.argv[1]):
    r = json.loads(l)
    if r["command"] == "node.create": print(r["result"]["id"]); break  # the first layer is the Landing frame
PY
)"
[ -n "$ROOT" ] || { echo "error: Landing id not found in run output" >&2; exit 1; }

q() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":%s}}\n' "$1" "$2" "$3"; }
{
  echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"capture","version":"0"}}}'
  echo '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  q 2 open_file "{\"path\":\"$TMP/doc.figcraft\"}"
  q 3 get_node "{\"id\":\"$ROOT\",\"depth\":64}"
  q 4 run_command "{\"command\":\"inspect.code\",\"params\":{\"id\":\"$ROOT\",\"language\":\"html\"}}"
  q 5 run_command '{"command":"variable.list","params":{}}'
  q 6 run_command "{\"command\":\"inspect.assets\",\"params\":{\"ids\":[\"$ROOT\"]}}"
  q 7 run_command "{\"command\":\"file.exportLayers\",\"params\":{\"ids\":[\"$ROOT\"],\"assets\":true}}"
  sleep 4
} | "$CLI" mcp --no-system-fonts --automation-read-root "$TMP" 2>/dev/null > "$TMP/mcp.out"

python3 -I - "$TMP/mcp.out" "$FX" <<'PY'
import sys, json
out = {}
for l in open(sys.argv[1]):
    m = json.loads(l)
    if "id" in m: out[m["id"]] = m
def text(i):
    r = out[i]["result"]
    assert not r.get("isError"), r
    return r["content"][0]["text"]
fx = sys.argv[2]
def dump(name, s):
    open(f"{fx}/{name}", "w").write(json.dumps(json.loads(s), indent=4, ensure_ascii=False) + "\n")
dump("node.json", text(3))
open(f"{fx}/code.html", "w").write(json.loads(text(4))["code"])
dump("variables.json", text(5))
dump("assets.json", text(6))
dump("export-files.json", text(7))
PY
echo "ok: fixtures in Tests/Fixtures/html-export"
