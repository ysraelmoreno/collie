#!/bin/bash
# Changed files → test targets to run, as one stdout line: empty (nothing to test), ALL, or a
# `swift test --filter` regex like CollieAppTests|CollieThemeTests.
# Usage: scripts/ci/affected-tests.sh [<base>]      files changed between merge-base(<base>, HEAD) and HEAD
#        scripts/ci/affected-tests.sh --files <f>…  explicit list, no git
set -eu
cd "$(dirname "$0")/../.."

if [ "${1:-}" = --files ]; then
  shift
  FILES="$(printf '%s\n' "$@")"
else
  BASE="${1:-origin/main}"
  FILES="$(git diff --name-only "$(git merge-base "$BASE" HEAD)" HEAD)"
fi

# Manifest, resources and shared fixtures can affect anything.
if printf '%s\n' "$FILES" | grep -qE '^(Package\.swift$|Package\.resolved$|Resources/|Tests/Fixtures/)'; then
  echo ALL
  exit 0
fi

# Target names touched: Sources/<T>/… and Tests/<X>/…. Everything else (docs, scripts/ci, …) maps to no Swift test.
SEEDS="$(printf '%s\n' "$FILES" | sed -nE 's#^(Sources|Tests)/([^/]+)/.*#\2#p' | sort -u)"
if [ -z "$SEEDS" ]; then
  echo
  exit 0
fi

# A test target is affected when it, or anything it depends on transitively, is a touched target.
swift package dump-package | jq -r --arg seeds "$SEEDS" '
  ($seeds | split("\n")) as $s
  | (.targets | map({key: .name, value: [.dependencies[] | (.byName // .target // .product)[0]]}) | from_entries) as $deps
  | def closure: . as $n | [$n] + [($deps[$n] // [])[] | closure] | unique;
  [.targets[] | select(.type == "test") | .name | select((closure - $s) != closure)] | sort | join("|")'
