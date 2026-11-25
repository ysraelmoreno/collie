#!/bin/bash
# Offline check of scripts/ci/plugin-catalog.sh and the local `collie plugin tree-hash|catalog-keygen|catalog-sign|
# catalog-verify` (PRD M4), with a copy of Examples/plugins/vizinho, a fake helper and a simulated codesign.
# Run: scripts/ci/test-plugin-catalog.sh   (COLLIE=<path to a built collie> skips the build)
set -euo pipefail
cd "$(dirname "$0")/../.."
S="$PWD/scripts/ci/plugin-catalog.sh"
if [ -z "${COLLIE:-}" ]; then
  swift build --product collie >/dev/null
  COLLIE="$(swift build --product collie --show-bin-path)/collie"
fi
export COLLIE
T="$(mktemp -d)"; trap 'chmod -R u+w "$T"; rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
refused() { local why="$1"; shift; set +e; "$@" >/dev/null 2>"$T/err"; local rc=$?; set -e; [ $rc != 0 ] || fail "accepted: $why"; }

mkdir -p "$T/bin" "$T/pkg"
printf '#!/bin/sh\necho "Identifier=dev.collie.plugin.vizinho" >&2\necho "TeamIdentifier=AG8JQAH6YB" >&2\n' > "$T/bin/codesign"
chmod +x "$T/bin/codesign"
export CODESIGN="$T/bin/codesign"
P="$T/pkg/vizinho"
cp -R Examples/plugins/vizinho "$P"
mkdir "$P/bin"; printf '#!/bin/sh\nexit 0\n' > "$P/bin/vizinho"; chmod +x "$P/bin/vizinho"
pack() { COPYFILE_DISABLE=1 tar -czf "$T/vizinho-$1.tar.gz" -C "$T/pkg" vizinho; }
pack 0.1.0

# keygen: private 0600 (never overwritten), public printed
PUB="$("$COLLIE" plugin catalog-keygen --out "$T/key")"
[ "$(stat -f %Lp "$T/key")" = 600 ] || fail "private key mode"
[ "$(printf '%s' "$PUB" | base64 -D | wc -c | tr -d ' ')" = 32 ] || fail "public key is not 32 raw bytes"
refused "keygen over an existing file" "$COLLIE" plugin catalog-keygen --out "$T/key"
KEY="$(cat "$T/key")"

# tree-hash: stable, and refused on a link
H="$("$COLLIE" plugin tree-hash "$P")"
[[ "$H" =~ ^[0-9a-f]{64}$ ]] || fail "tree-hash output: $H"
[ "$("$COLLIE" plugin tree-hash "$P")" = "$H" ] || fail "tree-hash not stable"
cp -R "$P" "$T/linked"; ln -s /etc/hosts "$T/linked/ui/x"
set +e; "$COLLIE" plugin tree-hash "$T/linked" >/dev/null 2>"$T/err"; rc=$?; set -e
[ $rc = 1 ] || fail "tree-hash with a link exited $rc"
grep -q "link" "$T/err" || fail "tree-hash link reason: $(cat "$T/err")"

# a new item needs a summary
refused "new item without SUMMARY" "$S" - vizinho 0.1.0 "$T/vizinho-0.1.0.tar.gz" "$P" "$T/x.json"
[ ! -e "$T/x.json" ] || fail "wrote output without SUMMARY"

# first catalog, from nothing
export SUMMARY="Ao editar um arquivo, o agente recebe a forma que os arquivos irmãos seguem."
"$S" - vizinho 0.1.0 "$T/vizinho-0.1.0.tar.gz" "$P" "$T/c1.json" || fail "first: $(cat "$T/err" 2>/dev/null)"
C="$T/c1.json"
jq -e '.format == 1 and .sequence == 1 and (.generatedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
  and .publishers == [{"id":"collie","name":"Collie","reviewedBy":"collie"}]' "$C" >/dev/null || fail "head: $(cat "$C")"
jq -e --arg s "$SUMMARY" '.plugins | length == 1 and .[0].id == "vizinho" and .[0].name == "Vizinho" and .[0].publisher == "collie"
  and .[0].kind == "agent" and .[0].summary == $s and (.[0].minCollie | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' "$C" >/dev/null || fail "item"
V='.plugins[0].versions[0]'
[ "$(jq -r "$V.treeSha256" "$C")" = "$H" ] || fail "treeSha256 != tree-hash"
[ "$(jq -r "$V.sha256" "$C")" = "$(shasum -a 256 "$T/vizinho-0.1.0.tar.gz" | cut -d' ' -f1)" ] || fail "sha256"
[ "$(jq -r "$V.size" "$C")" = "$(stat -f %z "$T/vizinho-0.1.0.tar.gz")" ] || fail "size"
[ "$(jq -r "$V.url" "$C")" = "https://github.com/ysraelmoreno/collie/releases/download/plugin-vizinho-v0.1.0/vizinho-0.1.0.tar.gz" ] || fail "url"
jq -e "$V | .version == \"0.1.0\" and .permissions == {\"project\":\"read\"} and .hooks == [\"edit\",\"stop\"]
  and .helperTeamId == \"AG8JQAH6YB\" and .recalled == null" "$C" >/dev/null || fail "version fields: $(jq -c "$V" "$C")"

# sign + verify with the printed public key
PLUGIN_CATALOG_KEY="$KEY" "$COLLIE" plugin catalog-sign "$C" --key-env PLUGIN_CATALOG_KEY >/dev/null
[ "$(wc -c < "$C.sig" | tr -d ' ')" = 64 ] || fail "signature is not 64 raw bytes"
"$COLLIE" plugin catalog-verify "$C" --public "$PUB" >/dev/null || fail "verify: $(cat "$T/err")"
refused "sign without the key in env" env -u PLUGIN_CATALOG_KEY "$COLLIE" plugin catalog-sign "$C" --key-env PLUGIN_CATALOG_KEY
OTHER="$("$COLLIE" plugin catalog-keygen --out "$T/other")"
refused "verify with another key" "$COLLIE" plugin catalog-verify "$C" --public "$OTHER"
cp "$C" "$T/t.json"; cp "$C.sig" "$T/t.json.sig"; sed -i '' 's/"sequence": 1/"sequence": 9/' "$T/t.json"
refused "verify a tampered catalog" "$COLLIE" plugin catalog-verify "$T/t.json" --public "$PUB"

# a new version: sequence + 1, both versions kept
jq '.version = "0.2.0"' "$P/collie-plugin.json" > "$T/m" && mv "$T/m" "$P/collie-plugin.json"
pack 0.2.0
"$S" "$C" vizinho 0.2.0 "$T/vizinho-0.2.0.tar.gz" "$P" "$T/c2.json"
jq -e '.sequence == 2 and (.plugins | length == 1) and ([.plugins[0].versions[].version] == ["0.1.0","0.2.0"])' "$T/c2.json" >/dev/null \
  || fail "second version: $(jq -c '[.sequence, [.plugins[0].versions[].version]]' "$T/c2.json")"
[ "$(jq -r '.plugins[0].versions[1].treeSha256' "$T/c2.json")" = "$("$COLLIE" plugin tree-hash "$P")" ] || fail "treeSha256 0.2.0"
# the same version again replaces it
"$S" "$T/c2.json" vizinho 0.2.0 "$T/vizinho-0.2.0.tar.gz" "$P" "$T/c2b.json"
jq -e '.sequence == 3 and ([.plugins[0].versions[].version] == ["0.1.0","0.2.0"])' "$T/c2b.json" >/dev/null || fail "replace"

# refusals: nothing written
refused "manifest version != argument" "$S" "$C" vizinho 0.3.0 "$T/vizinho-0.2.0.tar.gz" "$P" "$T/x.json"
cp "$T/vizinho-0.1.0.tar.gz" "$T/vizinho-0.2.1.tar.gz"
jq '.version = "0.2.1"' "$P/collie-plugin.json" > "$T/m" && mv "$T/m" "$P/collie-plugin.json"
refused "package differs from the folder" "$S" "$C" vizinho 0.2.1 "$T/vizinho-0.2.1.tar.gz" "$P" "$T/x.json"
printf '{"format":2}' > "$T/f2.json"
refused "unknown format" "$S" "$T/f2.json" vizinho 0.2.1 "$T/vizinho-0.2.1.tar.gz" "$P" "$T/x.json"
printf '#!/bin/sh\necho "TeamIdentifier=not set" >&2\n' > "$T/bin/codesign"
pack 0.2.1
refused "unsigned helper" "$S" "$C" vizinho 0.2.1 "$T/vizinho-0.2.1.tar.gz" "$P" "$T/x.json"
[ ! -e "$T/x.json" ] || fail "wrote output on a refusal"

# recall: reason and date filled, sequence + 1, still signs and verifies
"$S" --recall "$T/c2b.json" vizinho 0.1.0 "vaza o caminho do projeto" "$T/c3.json"
jq -e '.sequence == 4 and .plugins[0].versions[0].recalled.reason == "vaza o caminho do projeto"
  and (.plugins[0].versions[0].recalled.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
  and .plugins[0].versions[1].recalled == null' "$T/c3.json" >/dev/null || fail "recall: $(jq -c '.plugins[0].versions' "$T/c3.json")"
PLUGIN_CATALOG_KEY="$KEY" "$COLLIE" plugin catalog-sign "$T/c3.json" --key-env PLUGIN_CATALOG_KEY >/dev/null
"$COLLIE" plugin catalog-verify "$T/c3.json" --public "$PUB" >/dev/null || fail "verify recalled"
refused "recall of an unknown version" "$S" --recall "$T/c2b.json" vizinho 9.9.9 "x" "$T/x.json"
refused "recall without a reason" "$S" --recall "$T/c2b.json" vizinho 0.1.0 "" "$T/x.json"
[ ! -e "$T/x.json" ] || fail "wrote output on a recall refusal"
echo "ok: plugin-catalog.sh"
