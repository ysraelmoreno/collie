#!/bin/bash
# Prints "<id> <versão>" for each plug-in version a diff touches (plugins/<id>/<versão>/… or plugins/<id>/<versão>.json),
# once each. Any other path under plugins/ except plugins/<id>/plugin.json is refused.
#   scripts/touched.sh <base-sha> <head-sha>
set -euo pipefail
export LC_ALL=C
git diff --name-only "$1" "$2" -- plugins | while read -r f; do
  if [[ "$f" =~ ^plugins/([a-z][a-z0-9-]{1,31})/([0-9]+\.[0-9]+\.[0-9]+)(/.+|\.json)$ ]]; then
    echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
  elif [[ "$f" =~ ^plugins/[a-z][a-z0-9-]{1,31}/plugin\.json$ ]]; then
    :
  else
    echo "caminho fora do formato: $f (plugins/<id>/<X.Y.Z>/… ou plugins/<id>/<X.Y.Z>.json)" >&2; exit 1
  fi
done | sort -u
