#!/bin/bash
# The check of a pull request (.github/workflows/check.yml). Prints every problem, exits 1 if any.
#   scripts/check-pr.sh <base-sha> <head-sha> <login do autor do PR>
# Rules: the publisher of a plug-in is plugins/<id>/plugin.json {"publisher","summary"}; a publisher id is its owner's
# GitHub login in lower case (publishers/<login>.json), so "the PR author owns publishers/<id>.json" is id == login.
# `collie` is the app owner's. A published version (present in base) never changes. Each touched version passes
# `collie plugin validate`. Env: COLLIE (default collie), OWNER (default ysraelmoreno).
set -uo pipefail
export LC_ALL=C
BASE="$1" HEAD="$2" LOGIN="$(printf '%s' "$3" | tr 'A-Z' 'a-z')"
COLLIE="${COLLIE:-collie}" OWNER="${OWNER:-ysraelmoreno}"
rc=0; bad() { echo "::error::$*"; rc=1; }
inbase() { git cat-file -e "$BASE:$1" 2>/dev/null; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
S="$(cd "$(dirname "$0")" && pwd)"   # the base's scripts (check.yml): a PR never changes its own check

me="$LOGIN"; [ "$LOGIN" = "$OWNER" ] && me=collie
[[ "$me" =~ ^[a-z][a-z0-9-]{1,31}$ ]] || bad "login '$LOGIN' não serve de id de publisher (a-z, 0-9, '-', 2 a 32)"
if [ "$me" != collie ]; then
  for f in $(git diff --name-only "$BASE" "$HEAD" | grep -vE '^(plugins|publishers)/'); do bad "$f: só o dono mexe fora de plugins/ e publishers/"; done
fi

# publishers/: only your own file, with the fields
for f in $(git diff --name-only "$BASE" "$HEAD" -- publishers); do
  [ "$f" = "publishers/$me.json" ] || { bad "$f: o autor do PR ($LOGIN) só edita publishers/$me.json"; continue; }
  [ -f "$f" ] || { bad "$f: não apague o seu publisher"; continue; }
  jq -e --arg id "$me" '.id == $id and (.name | type == "string" and length > 0 and length <= 64)
     and (.contact | type == "string" and length > 0) and (.url | type == "string" and startswith("https://"))' "$f" >/dev/null \
    || bad "$f: precisa de {\"id\": \"$me\", \"name\", \"contact\", \"url\": \"https://…\"}"
done

touched="$("$S/touched.sh" "$BASE" "$HEAD")" || { bad "o PR mexe em caminhos fora do formato (acima)"; touched=""; }
ids="$(git diff --name-only "$BASE" "$HEAD" -- 'plugins/*/plugin.json' | cut -d/ -f2; printf '%s\n' "$touched" | cut -d' ' -f1)"
for id in $(printf '%s\n' "$ids" | sort -u); do
  [ -n "$id" ] || continue
  M="plugins/$id/plugin.json"
  [ -f "$M" ] || { bad "$M ausente: {\"publisher\": \"$me\", \"summary\": \"…\"}"; continue; }
  pub="$(jq -r '.publisher // ""' "$M")"
  jq -e '(.summary | type == "string" and length > 0 and length <= 200)' "$M" >/dev/null || bad "$M: summary (1 a 200 caracteres, pt-BR)"
  if inbase "$M"; then
    [ "$(git show "$BASE:$M" | jq -r '.publisher // ""')" = "$pub" ] || bad "$M: o publisher de um plug-in não muda"
  fi
  [ "$pub" = "$me" ] || bad "$id é de '$pub': o autor do PR ($LOGIN) só publica como '$me'"
  [ -f "publishers/$pub.json" ] || bad "publishers/$pub.json ausente: o primeiro PR de um autor traz o seu publishers/"
done

while read -r id ver; do
  [ -n "${id:-}" ] || continue
  for p in "plugins/$id/$ver" "plugins/$id/$ver.json"; do
    inbase "$p" && bad "$id $ver já foi publicado: suba a versão"
  done
  if ! "$S/assemble.sh" "$id" "$ver" "$T/$id-$ver" 2>"$T/err"; then bad "$id $ver: $(cat "$T/err")"; continue; fi
  if out="$("$COLLIE" plugin validate "$T/$id-$ver/$id")"; then
    echo "$id $ver: $out" | tr '\n' ' '; echo
  else
    while read -r l; do bad "$id $ver: $l"; done <<< "$out"
  fi
done <<< "$touched"
exit $rc
