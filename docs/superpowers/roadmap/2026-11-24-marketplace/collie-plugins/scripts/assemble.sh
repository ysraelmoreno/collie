#!/bin/bash
# Assembles plug-in <id> <versão> into <out>/<id> (the package folder), from the folder plugins/<id>/<versão>/ or from
# plugins/<id>/<versão>.json ({"repo": "https://github.com/<autor>/<repo>", "tag": "<tag>", "path": "<pasta>"}).
# The manifest must say that id and version. Nothing of the author's repo runs: it is cloned and copied, no more.
#   scripts/assemble.sh <id> <versão> <out>
set -euo pipefail
export LC_ALL=C
ID="$1" VER="$2" OUT="$3"
die() { echo "assemble: $*" >&2; exit 1; }
mkdir -p "$OUT"; P="$OUT/$ID"
[ ! -e "$P" ] || die "$P já existe"
if [ -d "plugins/$ID/$VER" ]; then
  [ ! -e "plugins/$ID/$VER.json" ] || die "plugins/$ID/$VER: pasta ou .json, não os dois"
  cp -R "plugins/$ID/$VER" "$P"
elif [ -f "plugins/$ID/$VER.json" ]; then
  J="plugins/$ID/$VER.json"
  REPO="$(jq -er '.repo' "$J")" TAG="$(jq -er '.tag' "$J")" SUB="$(jq -er '.path' "$J")" || die "$J: repo, tag e path"
  [[ "$REPO" =~ ^https://github\.com/[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] || die "$J: repo tem que ser https://github.com/<autor>/<repo>"
  [[ "$TAG" =~ ^[A-Za-z0-9._/-]+$ && "$TAG" != -* ]] || die "$J: tag inválida"
  [[ "$SUB" =~ ^[A-Za-z0-9._/-]*$ && "$SUB" != /* && "/$SUB/" != */../* ]] || die "$J: path inválido"
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  GIT_TERMINAL_PROMPT=0 git -c advice.detachedHead=false clone -q --depth 1 --branch "$TAG" -- "$REPO" "$T/src" \
    || die "não consegui clonar $REPO na tag $TAG"
  [ -d "$T/src/$SUB" ] && [ ! -L "$T/src/$SUB" ] || die "$SUB não é uma pasta em $REPO@$TAG"
  cp -R "$T/src/$SUB" "$P"
  rm -rf "$P/.git"
else
  die "nem plugins/$ID/$VER/ nem plugins/$ID/$VER.json"
fi
jq -e --arg id "$ID" --arg v "$VER" '.id == $id and .version == $v' "$P/collie-plugin.json" >/dev/null \
  || die "o manifesto diz $(jq -r '"\(.id) \(.version)"' "$P/collie-plugin.json" 2>/dev/null || echo '?'), não $ID $VER"
