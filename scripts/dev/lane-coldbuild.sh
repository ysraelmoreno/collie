#!/bin/sh
# How long a lane's cold build takes on this machine, so the owner can decide when `collie work run --parallel` pays off.
#
#   scripts/dev/lane-coldbuild.sh [<swift build args>]
#
# A lane (docs/referencia.md, "Tarefas em paralelo") is a fresh worktree with no build cache: every lane, and every new
# attempt, pays a cold `swift build`. This makes one throwaway worktree of HEAD where the loop puts its lanes
# (<repo>/.collie/paddocks/), times `swift build` in it and removes it. It only measures and prints: nothing of the
# checkout, of the installed Collie or of a running loop is touched. Takes minutes; not part of the CI nor of any check.
# The worktree is detached and is not named `lane-*` nor given a `collie/lane/*` branch, so the daemon's lane sweep
# never takes it for an orphan while the build runs.
set -eu
common=$(git rev-parse --path-format=absolute --git-common-dir)
case $common in */.git) root=${common%/.git} ;; *) root=$(git rev-parse --show-toplevel) ;; esac
dir=$root/.collie/paddocks/coldbuild-$$
[ -e "$dir" ] && { echo "lane-coldbuild: $dir already exists" >&2; exit 1; }

cleanup() {
  git -C "$root" worktree remove --force "$dir" >/dev/null 2>&1 || rm -rf "$dir"
  git -C "$root" worktree prune
}
trap cleanup EXIT
trap 'exit 130' INT TERM

head=$(git rev-parse --short HEAD)
t0=$(date +%s)
git -C "$root" worktree add --detach "$dir" HEAD >/dev/null
t1=$(date +%s)
echo "lane-coldbuild: worktree of $head at $dir ($((t1 - t0)) s); swift build $* (cold) ..."
status=0
(cd "$dir" && swift build "$@") >"$dir/.coldbuild.log" 2>&1 || status=$?
t2=$(date +%s)
[ "$status" -eq 0 ] || { tail -n 20 "$dir/.coldbuild.log" >&2; echo "lane-coldbuild: swift build failed (exit $status) after $((t2 - t1)) s" >&2; exit "$status"; }
s=$((t2 - t1))
echo "lane-coldbuild: cold swift build of $head: ${s} s ($((s / 60)) min $((s % 60)) s), $(du -sh "$dir/.build" | cut -f1) of build products"
echo "lane-coldbuild: every lane and every new attempt pays this before its check; --parallel pays off for tasks longer than that"
