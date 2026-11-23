#!/usr/bin/env bash
# teardown.sh — remove a worktree only when nothing unlanded can be lost (DESIGN.md §12). Run it
# in the project's main checkout.
#
#   teardown.sh <worktree> [--pr <n>] [--base <branch>] [--worker <id>]
#   teardown.sh <worktree> --scout --report <file> [--worker <id>]
#
# A worker's worktree goes only when its HEAD is safe, by any one of these facts read now:
#   - HEAD is contained in a branch on the remote
#   - --pr <n>: GitHub reports that PR merged, and HEAD is contained in the PR's head
#   - --base <branch>: HEAD's content is identical to that branch on the remote
# A scout's worktree goes only when its report exists, is not empty, and lies outside the worktree.
# Uncommitted or untracked files always refuse: the worktree is removed without force. The local
# branch goes with it, except a scout's branch whose HEAD is not safe, which is kept.
# --worker <id> also removes that worker's records (state, meta, guard config, inbox), so it no
# longer counts as in flight.
# Exit: 0 removed · 2 refused · 1 the facts could not be read.
# Env: DISPATCH_GH (gh), DISPATCH_REPO (owner/name), DISPATCH_REMOTE (origin).
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"
usage() {
  echo "usage: teardown.sh <worktree> [--pr <n>] [--base <branch>] [--worker <id>]" >&2
  echo "       teardown.sh <worktree> --scout --report <file> [--worker <id>]" >&2; exit 1
}

wt=; pr=; base=; worker=; scout=0; report=
while [ $# -gt 0 ]; do
  case $1 in
    --pr) pr=${2:-}; shift ;;
    --base) base=${2:-}; shift ;;
    --worker) worker=${2:-}; shift ;;
    --report) report=${2:-}; shift ;;
    --scout) scout=1 ;;
    -*) usage ;;
    *) [ -z "$wt" ] || usage; wt=$1 ;;
  esac
  shift
done
pr=${pr#\#}
[ -n "$wt" ] || usage
case $pr in *[!0-9]*) usage ;; esac
case $worker in *[!A-Za-z0-9._-]*) usage ;; esac
gh=${DISPATCH_GH:-gh}; remote=${DISPATCH_REMOTE:-origin}
die() { echo "teardown: $*" >&2; exit 1; }

# The target must be the root of a linked worktree of this project, never the main checkout.
real() { [ -n "$1" ] && (cd "$1" 2>/dev/null && pwd -P); }
gitdir() { (cd "$1" 2>/dev/null && real "$(git rev-parse "$2" 2>/dev/null)"); }  # dir, flag
st=$(ds_state) || exit 1
common=$(gitdir . --git-common-dir) || die "cannot find this project's git dir"
wt=$(real "$wt") || die "no such worktree"
wcommon=$(gitdir "$wt" --git-common-dir) && wgit=$(gitdir "$wt" --git-dir) &&
  [ "$wcommon" = "$common" ] || die "$wt is not a worktree of this project"
[ "$wgit" != "$common" ] || die "$wt is the main checkout, not a linked worktree"
[ "$(gitdir "$wt" --show-toplevel)" = "$wt" ] || die "$wt is inside a worktree, not its root"
head=$(git -C "$wt" rev-parse HEAD) || die "cannot read HEAD of $wt"
branch=$(git -C "$wt" symbolic-ref -q --short HEAD)

why=
safe() {  # is HEAD's work provably held somewhere else? sets $why to the fact that proves it
  local state tree
  if [ -n "$(git branch -r --list "$remote/*" --contains "$head" 2>/dev/null)" ]; then
    why="HEAD is on a branch of $remote"; return 0
  fi
  if [ -n "$pr" ]; then
    command -v jq >/dev/null || die "jq is required"
    repo=${DISPATCH_REPO:-$($gh repo view --json nameWithOwner --jq .nameWithOwner)} || exit 1
    state=$($gh pr view "$pr" --repo "$repo" --json state | jq -r .state) ||
      die "cannot read PR #$pr"
    if [ "$state" = MERGED ] &&
      git fetch -q "$remote" "+refs/pull/$pr/head:refs/dispatch/teardown-$pr" &&
      git merge-base --is-ancestor "$head" "refs/dispatch/teardown-$pr"; then
      why="HEAD is in merged PR #$pr"; return 0
    fi
  fi
  if [ -n "$base" ] && tree=$(git rev-parse -q --verify "refs/remotes/$remote/$base^{tree}") &&
    [ "$tree" = "$(git rev-parse "$head^{tree}")" ]; then
    why="HEAD is identical in content to $remote/$base"; return 0
  fi
  return 1
}
trap '[ -z "$pr" ] || git update-ref -d "refs/dispatch/teardown-$pr" 2>/dev/null' EXIT

fetched=0; git fetch -q --prune "$remote" && fetched=1
keep_branch=0
if [ "$scout" -eq 1 ]; then
  [ -s "$report" ] || { echo "refused: scout report '${report}' is missing or empty"; exit 2; }
  rp=$(real "$(dirname "$report")")/$(basename "$report")
  case $rp in "$wt"/*)
    echo "refused: the report lies inside the worktree and would be removed with it"; exit 2 ;;
  esac
  { [ "$fetched" -eq 1 ] && safe; } || keep_branch=1
  why="scout report $rp exists${why:+; $why}"
else
  [ "$fetched" -eq 1 ] || die "cannot fetch from $remote, so nothing proves HEAD is safe"
  safe || {
    echo "refused: unlanded work: HEAD $head is not on $remote, not in a merged PR's head," \
      "and not identical to the base"; exit 2; }
fi

out=$(git worktree remove "$wt" 2>&1) || { echo "refused: $out"; exit 2; }
if [ -n "$branch" ]; then
  if [ "$keep_branch" -eq 1 ]; then
    echo "kept branch $branch: its HEAD $head is not on $remote"
  else
    git branch -q -D "$branch" || echo "teardown: note: branch $branch was not deleted" >&2
  fi
fi
if [ -n "$worker" ]; then  # every record start.sh and inbox.sh keep for it
  rm -f "$st/workers/$worker".* "$st/guard/$worker.conf"; rm -rf "$st/inbox/$worker"
fi
echo "removed $wt ($why)"
