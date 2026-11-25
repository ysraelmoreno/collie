#!/bin/bash
# Writes the next plugins.json (format 1, spec docs/superpowers/specs/2026-11-24-plugin-marketplace-design.md) from the
# current one: sequence + 1, generatedAt now. Signing is separate (`collie plugin catalog-sign`). Nothing is written on
# a refusal. Used by .github/workflows/plugins-release.yml; checked by scripts/ci/test-plugin-catalog.sh.
#
#   plugin-catalog.sh <atual.json|-> <id> <versão> <id>-<versão>.tar.gz <pasta-montada> <out.json>
#       adds (or replaces) that version: sha256/size of the package, treeSha256 (`collie plugin tree-hash`, the same
#       for the folder and the package's extracted copy), permissions/hooks of the manifest, helperTeamId of bin/*.
#       A new item takes its summary from $SUMMARY (kind: agent with hooks, else panel; minCollie: $MIN_COLLIE or
#       Resources/Info.plist).
#   plugin-catalog.sh --recall <atual.json> <id> <versão> "<motivo>" <out.json>
#
# Env: COLLIE (default collie), CODESIGN (default codesign).
set -euo pipefail
export LC_ALL=C
COLLIE="${COLLIE:-collie}" CODESIGN="${CODESIGN:-codesign}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REPO_URL="https://github.com/ysraelmoreno/collie/releases/download"
die() { echo "plugin-catalog: $*" >&2; exit 1; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

current() {   # $1: file or -; the catalog on stdout, format 1 only
  if [ "$1" = - ]; then
    echo '{"format":1,"generatedAt":"","sequence":0,"plugins":[],"publishers":[{"id":"collie","name":"Collie","reviewedBy":"collie"}]}'
    return
  fi
  [ -f "$1" ] || die "catálogo atual $1 não existe"
  jq -e '.format == 1 and (.sequence | type == "number") and (.plugins | type == "array")' "$1" >/dev/null \
    || die "$1 não é um catálogo format 1"
  cat "$1"
}
valid_id() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "id \"$1\" inválido"; }
valid_version() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "versão \"$1\" não é X.Y.Z"; }
write() { mv "$T/out" "$1"; }   # only once everything passed

if [ "${1:-}" = --recall ]; then
  [ $# = 6 ] || die "uso: --recall <atual.json> <id> <versão> \"<motivo>\" <out.json>"
  CUR="$2" ID="$3" VER="$4" WHY="$5" OUT="$6"
  valid_id "$ID"; valid_version "$VER"; [ -n "$WHY" ] || die "recall precisa de um motivo"
  current "$CUR" > "$T/cur"
  jq -e --arg id "$ID" --arg v "$VER" 'any(.plugins[] | select(.id == $id) | .versions[]; .version == $v)' "$T/cur" >/dev/null \
    || die "$ID $VER não está no catálogo"
  jq --arg id "$ID" --arg v "$VER" --arg why "$WHY" --arg at "$(now)" '
    .sequence += 1 | .generatedAt = $at
    | (.plugins[] | select(.id == $id) | .versions[] | select(.version == $v) | .recalled) = {reason: $why, at: $at}' \
    "$T/cur" > "$T/out"
  write "$OUT"; exit 0
fi

[ $# = 6 ] || die "uso: <atual.json|-> <id> <versão> <pacote.tar.gz> <pasta-montada> <out.json> (ou --recall …)"
CUR="$1" ID="$2" VER="$3" PKG="$4" DIR="$5" OUT="$6"
valid_id "$ID"; valid_version "$VER"
[ "$(basename "$PKG")" = "$ID-$VER.tar.gz" ] || die "o pacote tem que se chamar $ID-$VER.tar.gz"
[ -s "$PKG" ] || die "pacote $PKG vazio ou ausente"
M="$DIR/collie-plugin.json"
[ -f "$M" ] || die "$M não existe"
jq -e --arg id "$ID" --arg v "$VER" '.id == $id and .version == $v' "$M" >/dev/null \
  || die "o manifesto diz $(jq -r '"\(.id) \(.version)"' "$M"), não $ID $VER"
current "$CUR" > "$T/cur"

TREE="$("$COLLIE" plugin tree-hash "$DIR")" || die "a pasta não passaria na instalação"
# the package must hold exactly this folder (what the daemon will hash after extracting)
mkdir "$T/x"
tar -xzf "$PKG" -C "$T/x" || die "não consegui extrair $PKG"
[ "$(ls -A "$T/x")" = "$(basename "$DIR")" ] || die "o pacote tem que conter só a pasta $(basename "$DIR")"
[ "$("$COLLIE" plugin tree-hash "$T/x/$(basename "$DIR")")" = "$TREE" ] || die "o pacote difere da pasta montada"

TEAM=null
if [ -d "$DIR/bin" ]; then
  for b in "$DIR"/bin/*; do
    [ -f "$b" ] || continue
    t="$("$CODESIGN" -dv "$b" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    [[ "$t" =~ ^[A-Z0-9]{10}$ ]] || die "$(basename "$b") sem assinatura de time (TeamIdentifier=$t)"
    [ "$TEAM" = null ] || [ "$TEAM" = "\"$t\"" ] || die "helpers com times diferentes"
    TEAM="\"$t\""
  done
fi

NEW_ITEM=true
jq -e --arg id "$ID" 'any(.plugins[]; .id == $id)' "$T/cur" >/dev/null && NEW_ITEM=false
if [ "$NEW_ITEM" = true ] && [ -z "${SUMMARY:-}" ]; then die "$ID é novo no catálogo: defina SUMMARY"; fi
MIN="${MIN_COLLIE:-$(plutil -extract CFBundleShortVersionString raw -o - "$ROOT/Resources/Info.plist")}"

jq --slurpfile m "$M" --arg id "$ID" --arg v "$VER" --arg at "$(now)" --arg tree "$TREE" --argjson team "$TEAM" \
   --arg sha "$(shasum -a 256 "$PKG" | cut -d' ' -f1)" --argjson size "$(stat -f %z "$PKG")" \
   --arg url "$REPO_URL/plugin-$ID-v$VER/$ID-$VER.tar.gz" --arg summary "${SUMMARY:-}" --arg min "$MIN" '
  $m[0] as $man
  | {version: $v, url: $url, sha256: $sha, size: $size, treeSha256: $tree,
     permissions: ($man.permissions // {}), hooks: ($man.hooks // []), helperTeamId: $team, recalled: null} as $ver
  | .sequence += 1 | .generatedAt = $at
  | if any(.plugins[]; .id == $id) then .
    else .plugins += [{id: $id, name: $man.name, publisher: "collie", summary: $summary,
                       kind: (if ($man.hooks // []) == [] then "panel" else "agent" end), minCollie: $min, versions: []}]
    end
  | (.plugins[] | select(.id == $id) | .versions) |= (map(select(.version != $v)) + [$ver])' "$T/cur" > "$T/out"
write "$OUT"
