#!/bin/bash
# CI only (figcraft.yml): opens, or updates, the pull request figcraft-pin-<version> that writes the verified
# sha256/size/unpackedSize into Resources/figcraft-engine.json. Never pushes with git (persist-credentials: false):
# branch and commit go through the REST API with GH_TOKEN. Never merges, approves or triggers anything.
# Env: VERSION TAG SHA SIZE UNPACKED SOURCE (where the values come from) [FRESH=1], plus the GitHub Actions defaults.
set -euo pipefail
: "${VERSION:?}" "${TAG:?}" "${SHA:?}" "${SIZE:?}" "${UNPACKED:?}" "${SOURCE:?}" "${RUNNER_TEMP:?}"
PIN=Resources/figcraft-engine.json
R="$GITHUB_REPOSITORY"
BRANCH="figcraft-pin-$VERSION"
BASE="$GITHUB_REF_NAME"
NEW="$RUNNER_TEMP/figcraft-engine.json"
cp "$PIN" "$NEW"
res="$(scripts/ci/update-pin.sh "$NEW" "$VERSION" "$SHA" "$SIZE" "$UNPACKED" ${FRESH:+--fresh})"
if [ "$res" = unchanged ]; then echo "ok: the pin already holds the values of $TAG"; exit 0; fi

if ! gh api "repos/$R/git/ref/heads/$BRANCH" >/dev/null 2>&1; then
  gh api -X POST "repos/$R/git/refs" -f ref="refs/heads/$BRANCH" -f sha="$GITHUB_SHA" >/dev/null
  echo "created branch $BRANCH at $GITHUB_SHA"
fi
cur="$(gh api "repos/$R/contents/$PIN?ref=$BRANCH")"
if [ "$(jq -r .content <<<"$cur" | tr -d '\n' | base64 --decode)" != "$(cat "$NEW")" ]; then
  gh api -X PUT "repos/$R/contents/$PIN" -f branch="$BRANCH" -f sha="$(jq -r .sha <<<"$cur")" \
    -f content="$(base64 -i "$NEW" | tr -d '\n')" \
    -f message="figcraft: pin $VERSION com sha256, size e unpackedSize de $TAG" >/dev/null
  echo "committed $PIN on $BRANCH"
fi

RUN="$GITHUB_SERVER_URL/$R/actions/runs/$GITHUB_RUN_ID"
TITLE="figcraft $VERSION: sha256, size e unpackedSize no pin"
printf '%s\n' \
  "Preenche \`sha256\`, \`size\` e \`unpackedSize\` de \`$PIN\` com os valores do asset \`$TAG\`; o resto do pin não muda." \
  "" \
  "- Origem: $SOURCE, na rodada [$GITHUB_RUN_ID]($RUN) do workflow figcraft (commit $GITHUB_SHA)." \
  "- Release: \`$TAG\`" \
  "- sha256 do asset: \`$SHA\`" \
  "- size: \`$SIZE\`" \
  "- unpackedSize: \`$UNPACKED\`" \
  "" \
  "Aberto pelo workflow; ninguém aprova nem mergeia automaticamente. Depois do merge, a rodada do figcraft que o push dispara só confere o pin contra a release publicada e sai verde." \
  > "$RUNNER_TEMP/pin-pr.md"
num="$(gh pr list -R "$R" --head "$BRANCH" --state open --json number --jq '.[0].number // empty')"
if [ -n "$num" ]; then
  gh pr edit "$num" -R "$R" --title "$TITLE" --body-file "$RUNNER_TEMP/pin-pr.md"
  echo "::notice::PR #$num do pin atualizado ($BRANCH)"
else
  gh pr create -R "$R" --base "$BASE" --head "$BRANCH" --title "$TITLE" --body-file "$RUNNER_TEMP/pin-pr.md"
  echo "::notice::PR do pin aberto ($BRANCH)"
fi
