#!/usr/bin/env bash
# start.sh — start a worker that really started (DESIGN.md §12). Run it in the project's main
# checkout.
#
#   start.sh --brief <file> [--id <id>] [--agent claude|codex] [--scout]
#   start.sh --hook busy|idle|ended    what the worker session's own hooks call
#   start.sh --codex-hooks             print the hooks a Codex user installs and trusts once
#
# From the Brief it reads ISSUE #<n>, BASE <branch>, WORKTREE <path>, TIMEBOX <90m|2h>, and on
# the LIMITS line write=<paths> and deny=<paths>, up to the first ';'. A field it cannot read is
# a failed start: the issue is not Ready. Then, in order:
#   1. refuse over the WIP limit (the `WIP-limit:` rule line, default 3) with exit 75; scouts and
#      a relaunch of the same id do not count
#   2. create the linked worktree on branch issue-<n> from the remote base, or reuse it
#   3. record the folder as trusted in the agent's own config
#   4. write the worker's role-guard config (role, root, write, deny) and its hooks, and require
#      `role-guard --probe worker` to be denied through those hooks
#   5. write <id>.meta (issue, kind, agent, term, handle, worktree, branch, base, brief, timebox
#      in seconds, started) and open the agent in a new terminal with the Brief
#   6. wait up to DISPATCH_START_WAIT (60) seconds for the worker's own hook to write its state,
#      then append the start to the start log that board.sh accounts from
# A start that is not confirmed is a failed start, not a worker: its records are removed, and its
# terminal is left open to look at. No permission-bypass flag is ever added.
# Claude Code gets its hooks per session (--settings). Codex runs only hooks its user has reviewed
# and trusted, so its hooks are user-level and installed once: see --codex-hooks.
# Exit: 0 started and confirmed · 75 over the WIP limit, nothing started · 1 failed start, usage.
# Env: DISPATCH_AGENT (claude), DISPATCH_REMOTE (origin), DISPATCH_START_WAIT, and runtime.sh's.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"
# shellcheck source=runtime.sh
. "$here/runtime.sh"

if [ "${1:-}" = --hook ]; then  # never fails the session, and is inert outside a worker
  f="${DISPATCH_STATE:-}/workers/${DISPATCH_WORKER:-}"
  [ -n "${DISPATCH_WORKER:-}" ] && [ -f "$f.meta" ] || exit 0
  case ${2:-} in busy|idle|ended) ;; *) exit 0 ;; esac
  issue=$(sed -n 's/^issue=//p' "$f.meta")
  echo "$2 $(date +%s) ${issue:-0}" > "$f.state.tmp" && mv "$f.state.tmp" "$f.state"
  exit 0
fi
if [ "${1:-}" = --codex-hooks ]; then
  rt_hooks codex "$here/start.sh" "$here/role-guard.sh" ""; exit
fi

die() { echo "start: $*" >&2; exit 1; }
usage() { die "usage: start.sh --brief <file> [--id <id>] [--agent claude|codex] [--scout]"; }
brief=; id=; agent=${DISPATCH_AGENT:-claude}; kind=worker
while [ $# -gt 0 ]; do
  case $1 in
    --brief) brief=${2:-}; shift ;;
    --id) id=${2:-}; shift ;;
    --agent) agent=${2:-}; shift ;;
    --scout) kind=scout ;;
    *) usage ;;
  esac
  [ $# -eq 0 ] || shift
done
case $agent in claude|codex) ;; *) usage ;; esac
[ -n "$brief" ] || usage
[ -r "$brief" ] || die "cannot read the Brief $brief"
command -v jq >/dev/null || die "jq is required"
brief=$(cd "$(dirname "$brief")" && pwd -P)/$(basename "$brief")

# The Brief's fields, by their fixed labels (the format lives in skills/dispatch/SKILL.md).
field() { sed -n "$1" "$brief" | head -n 1; }
s='[[:space:]]'
issue=$(field 's/^ISSUE #\([0-9][0-9]*\).*/\1/p')
base=$(field "s/^ISSUE .*${s}BASE$s\{1,\}\([^[:space:]]\{1,\}\).*/\1/p")
wt=$(field "s/^ISSUE .*${s}WORKTREE$s\{1,\}\(.*[^[:space:]]\)$s*\$/\1/p")
limits=$(field "s/^LIMITS$s\{1,\}\([^;]*\).*/\1/p")
write=$(printf '%s' "$limits" | sed -n 's/.*write=//p' | sed "s/$s*deny=.*//; s/$s*\$//")
deny=$(printf '%s' "$limits" | sed -n 's/.*deny=//p' | sed "s/$s*write=.*//; s/$s*\$//")
box=$(field "s/^TIMEBOX$s\{1,\}\([0-9][0-9]*[mh]\).*/\1/p")
for need in issue:ISSUE base:BASE wt:WORKTREE write:LIMITS-write= box:TIMEBOX; do
  v=${need%%:*}
  [ -n "${!v}" ] || die "the Brief has no readable ${need#*:}: the issue is not Ready"
done
case $box in *h) timebox=$((${box%h} * 3600)) ;; *) timebox=$((${box%m} * 60)) ;; esac
id=${id:-w$issue}
case $id in [a-z]*) ;; *) usage ;; esac
case $id in *[!a-z0-9_-]*) usage ;; esac

root=$(git rev-parse --show-toplevel 2>/dev/null) || die "run inside the project's main checkout"
st=$(ds_state) || exit 1
term=$(rt_term) || exit 1
remote=${DISPATCH_REMOTE:-origin}; meta="$st/workers/$id.meta"
get() { sed -n "s/^$1=//p" "$2" 2>/dev/null | head -n 1; }
if [ -f "$meta" ] && rt_alive "$(get term "$meta")" "$(get handle "$meta")"; then
  die "worker $id is already running in $(get term "$meta") $(get handle "$meta")"
fi

# 1. Capacity.
if [ "$kind" = worker ]; then
  limit=$(ds_rule HEAD WIP-limit | head -n 1)
  case $limit in ''|*[!0-9]*) limit=3 ;; esac
  n=0
  for f in "$st"/workers/*.meta; do
    [ -f "$f" ] && [ "$f" != "$meta" ] && [ "$(get kind "$f")" = worker ] || continue
    n=$((n + 1))
  done
  if [ "$n" -ge "$limit" ]; then
    echo "queued: $n workers are in flight and the WIP limit is $limit; $id was not started"
    exit 75
  fi
fi

# 2. The worktree.
case $wt in /*) ;; *) wt="$root/$wt" ;; esac
if [ ! -d "$wt" ]; then
  branch="issue-$issue"; [ "$kind" = worker ] || branch="scout-$id"
  git fetch -q "$remote" "$base" || die "cannot fetch $base from $remote"
  if git rev-parse -q --verify "refs/heads/$branch" >/dev/null; then
    git worktree add -q "$wt" "$branch" || die "cannot create the worktree $wt"
  else
    git worktree add -q -b "$branch" "$wt" "$remote/$base" || die "cannot create the worktree $wt"
  fi
fi
wt=$(cd "$wt" && pwd -P) || die "cannot enter the worktree $wt"
common() { (cd "$1" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" && pwd -P); }
[ -n "$(common "$wt")" ] && [ "$(common "$wt")" = "$(common "$root")" ] ||
  die "$wt is not a worktree of this project"
branch=$(git -C "$wt" symbolic-ref -q --short HEAD) || die "$wt is on no branch"

# 3 and 4. Trust, the guard, the hooks; the guard must be seen denying before anything runs.
rt_trust "$agent" "$(cd "$root" && pwd -P)" "$wt" || die "cannot record $wt as trusted for $agent"
conf="$st/guard/$id.conf"; mkdir -p "$st/guard"
printf 'role=worker\nroot=%s\nwrite=%s\ndeny=%s\n' "$wt" "$write" "$deny" > "$conf"
settings="$st/workers/$id.settings.json"
if [ "$agent" = claude ]; then
  rt_hooks claude "$here/start.sh" "$here/role-guard.sh" "$conf" > "$settings" || exit 1
else
  settings="${CODEX_HOME:-$HOME/.codex}/hooks.json"
fi
probe=$(cd "$wt" && DISPATCH_GUARD_CONFIG="$conf" "$here/role-guard.sh" --probe worker \
  --settings "$settings" 2>&1) || {
  [ "$agent" != codex ] || echo "start: Codex runs only hooks you installed and trusted: add" \
    "the output of 'start.sh --codex-hooks' to $settings and trust it in Codex" >&2
  die "the worker's guard was not seen denying, so nothing was started: $probe"
}

# 5. The record, then the session.
failed() {  # reason — a start that is not confirmed leaves no worker behind
  rm -f "$meta" "$st/workers/$id.state" "$st/workers/$id.settings.json" "$conf"
  die "failed start of $id: $*"
}
rm -f "$st/workers/$id.state"
printf '%s\n' "issue=$issue" "kind=$kind" "agent=$agent" "term=$term" "worktree=$wt" \
  "branch=$branch" "base=$base" "brief=$brief" "timebox=$timebox" "started=$(date +%s)" > "$meta"
prompt="Act as this project's dispatch worker (the dispatch-worker skill). Your Brief is the"
prompt="$prompt file $brief: read it first."
cmd="DISPATCH_WORKER=$(rt_sq "$id") DISPATCH_STATE=$(rt_sq "$st") DISPATCH_ROLE=worker"
cmd="$cmd DISPATCH_GUARD_CONFIG=$(rt_sq "$conf") $(rt_agent "$agent" "$settings" "$prompt")"
handle=$(rt_open "$term" "$id" "$wt" "$cmd") && [ -n "$handle" ] ||
  failed "no $term terminal could be opened"
echo "handle=$handle" >> "$meta"

# 6. Confirmed by the worker's own hook, never by its screen.
wait=${DISPATCH_START_WAIT:-60}; case $wait in ''|*[!0-9]*) wait=60 ;; esac
i=0
while :; do
  state=$(cut -d' ' -f1 "$st/workers/$id.state" 2>/dev/null)
  case $state in busy|idle) break ;; esac
  [ "$i" -lt $((wait * 5)) ] || failed "it did not report busy within $wait s; its terminal" \
    "$term $handle is left open (a trust or sign-in screen is the usual cause)"
  i=$((i + 1)); sleep 0.2
done
echo "$(date +%s) $id $issue $kind $branch" >> "$st/starts"; ds_trim "$st/starts"  # for board.sh
echo "started $id issue=#$issue agent=$agent $term=$handle worktree=$wt timebox=$box"
