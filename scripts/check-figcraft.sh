#!/bin/bash
# Checks vendor/figcraft (from scripts/build-figcraft.sh): version, no third-party branding or
# public server, Inter embedded. Exits 0 only when all hold.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=vendor/figcraft
CLI="$OUT/bin/figcraft-cli"
fail() { echo "FAIL: $*" >&2; exit 1; }

for f in "$CLI" "$OUT/bin/figcraft-server" "$OUT/web/index.html"; do [ -e "$f" ] || fail "$f missing (run scripts/build-figcraft.sh)"; done
ls "$OUT"/web/*.wasm >/dev/null 2>&1 || fail "no .wasm in $OUT/web"

for bin in "$CLI" "$OUT/bin/figcraft-server"; do
  v="$("$bin" --version)"
  case "$v" in *0.7.0*) echo "ok: version: $v" ;; *) fail "version: $v" ;; esac
done
# The web build has no --version: its about/licence links name the source tag.
grep -aq "figcraft/blob/v0.7.0/" "$OUT"/web/*.wasm || fail "web build is not v0.7.0 (no blob/v0.7.0/ link in its .wasm)"
echo "ok: web build: v0.7.0"

hits="$(grep -rilE "artcraft|getartcraft|collab\.craftapps\.dev" "$OUT/bin" "$OUT/web" || true)"
[ -z "$hits" ] || fail "branding/public server found in: $hits"
echo "ok: no artcraft/getartcraft/collab.craftapps.dev in bin/ web/"

# One headless MCP session: initialize, then run_command text.fonts {"family":"Inter"}.
fonts="$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"check","version":"0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run_command","arguments":{"command":"text.fonts","params":{"family":"Inter"}}}}' \
  | "$CLI" mcp 2>/dev/null | python3 -I -c '
import json, sys
for line in sys.stdin:
    m = json.loads(line)
    if m.get("id") == 2:
        r = m.get("result", {})
        t = "".join(c.get("text", "") for c in r.get("content", []))
        print("" if r.get("isError") or t.strip() in ("", "[]", "{}", "null") else t)
')"
[ -n "$fonts" ] || fail "text.fonts {family: Inter} is empty: craft-fonts not embedded"
echo "ok: text.fonts Inter: $(echo "$fonts" | tr -d '\n' | cut -c1-160)"
echo "ok: figcraft check passed"
