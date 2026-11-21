#!/usr/bin/env bash
# Lists (and, asked, removes) the old per-agent build folders under <repo>/.build/ (M11.3; aval-suite-report P5).
#
#   scripts/dev/prune-builds.sh                          dry-run: each folder with its size and age (days)
#   scripts/dev/prune-builds.sh --apply --older-than <N> removes the folders whose mtime is older than N days
#
# Only `.build/<agent dir>`: never SwiftPM's own (debug, release, checkouts, repositories, artifacts, *.json, dot-dirs),
# never a symlink nor anything that resolves outside `<repo>/.build/`, never the folder of a live terminal
# (`collie list --all`, when collie is on PATH). PRUNE_ROOT overrides the repo root (test-prune-builds.sh).
set -euo pipefail
usage() { echo "usage: $0 [--apply --older-than <days>]" >&2; exit 2; }
apply=0 days=""
while [ $# -gt 0 ]; do
  case $1 in
    --apply) apply=1; shift ;;
    --older-than) [ $# -ge 2 ] || usage; days=$2; shift 2 ;;
    *) echo "prune-builds: unknown argument: $1" >&2; usage ;;
  esac
done
[ -z "$days" ] || [[ $days =~ ^[0-9]+$ ]] || { echo "prune-builds: --older-than takes whole days" >&2; usage; }
[ "$apply" -eq 0 ] || [ -n "$days" ] || { echo "prune-builds: --apply needs --older-than <days>" >&2; usage; }

root=$(cd "${PRUNE_ROOT:-$(dirname "$0")/../..}" && pwd -P)
build="$root/.build"
[ -d "$build" ] || { echo "prune-builds: no $build"; exit 0; }

# a live terminal's folder: its sanitized name, and for an attempt (`…-t<n>`) the loop's `laco-…` (AgentNaming.buildDir)
live=()
if command -v collie >/dev/null 2>&1; then
  while IFS=$'\t' read -r name _; do
    [ -n "$name" ] || continue
    plain=$(printf '%s' "${name:0:40}" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')
    live+=("$plain")
    if [[ $name =~ ^([a-z0-9]+(-[a-z0-9]+)+)-t[0-9]+$ ]]; then
      head=${BASH_REMATCH[1]} lane=""
      [[ $head =~ ^(.+-.+)(-f[0-9]+)$ ]] && head=${BASH_REMATCH[1]} lane=${BASH_REMATCH[2]}
      head="laco-$head"; head=${head:0:$((40 - ${#lane}))}
      while [ "${head%-}" != "$head" ]; do head=${head%-}; done
      live+=("$head$lane")
    fi
  done < <(collie list --all 2>/dev/null || true)
fi
is_live() { local l; for l in "${live[@]+"${live[@]}"}"; do [ "$1" = "$l" ] && return 0; done; return 1; }

now=$(date +%s) kept=0 removed=0
for d in "$build"/*; do
  [ -e "$d" ] || [ -L "$d" ] || continue
  base=${d##*/}
  case $base in debug|release|checkouts|repositories|artifacts|*.json|.*|arm64-*|x86_64-*) continue ;; esac
  if [ -L "$d" ] || [ ! -d "$d" ]; then echo "skip   $base (not a folder)"; continue; fi
  real=$(cd "$d" && pwd -P)
  case $real in "$build"/?*) ;; *) echo "skip   $base (outside $build)"; continue ;; esac
  age=$(( (now - $(stat -f %m "$d")) / 86400 ))
  size=$(du -sh "$d" 2>/dev/null | cut -f1)
  if is_live "$base"; then echo "live   $base $size ${age}d"; kept=$((kept + 1)); continue; fi
  if [ "$apply" -eq 1 ] && [ "$age" -gt "$days" ]; then
    case $real in "$build"/?*) rm -rf -- "$real" ;; esac
    echo "remove $base $size ${age}d"; removed=$((removed + 1))
  else
    echo "keep   $base $size ${age}d"; kept=$((kept + 1))
  fi
done
[ "$apply" -eq 1 ] || echo "prune-builds: dry-run; remove with --apply --older-than <days>"
echo "prune-builds: $removed removed, $kept kept"
