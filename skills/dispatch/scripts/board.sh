#!/usr/bin/env bash
# board.sh — the board, rendered from records every time (DESIGN.md §12). Run it anywhere in the
# project. It prints at most 80 lines and overwrites .dispatch/board.md with the same text.
#
#   board.sh                    render the board
#   board.sh --stage-reported   mark that a stage report was just given; accounting restarts here
#
# Sources, read now: `gh` issue and PR lists, each worker's records (workers/<id>.meta and .state),
# the start log start.sh appends to, the watcher's lock and beacon, and the wake queue. It keeps
# no progress of its own: nothing it writes is read back, except the stage mark above.
# Every worker started since the last stage report is listed with its end, the first that holds:
#   replaced   a later start exists for the same issue
#   landed     the PR from its branch is merged
#   running    its records exist and its session is busy or idle
#   absorbed   its records are gone and its issue is closed with no PR of its own landed
# A worker with none of these is flagged with "!": its session is over or its records are gone,
# and its work is neither landed nor absorbed.
# Exit: 0 rendered · 1 GitHub could not be read (the board is still written, and says so).
# Env: DISPATCH_GH (gh), DISPATCH_REPO (owner/name).
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"
st=$(ds_state) || exit 1
case ${1:-} in
  --stage-reported) date +%s > "$st/stage-report"; echo "stage report marked"; exit 0 ;;
  '') ;;
  *) echo "usage: board.sh [--stage-reported]" >&2; exit 1 ;;
esac
command -v jq >/dev/null || { echo "board: jq is required" >&2; exit 1; }
gh=${DISPATCH_GH:-gh}; now=$(date +%s); rc=0
repo=${DISPATCH_REPO:-$($gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)}
issues=$($gh issue list --repo "$repo" --state all --limit 200 \
  --json number,title,state,labels 2>/dev/null) || { issues='[]'; rc=1; }
prs=$($gh pr list --repo "$repo" --state all --limit 200 \
  --json number,title,state,headRefName,isDraft 2>/dev/null) || { prs='[]'; rc=1; }

age() {  # seconds — a short age
  if [ "$1" -lt 3600 ]; then echo "$(($1 / 60))m"
  elif [ "$1" -lt 172800 ]; then echo "$(($1 / 3600))h"; else echo "$(($1 / 86400))d"; fi
}
get() { sed -n "s/^$1=//p" "$st/workers/$2.meta" 2>/dev/null | head -n 1; }
pr_of() {  # branch state — the number of that branch's PR in that state, if any
  printf '%s' "$prs" | jq -r --arg b "$1" --arg s "$2" \
    '[.[] | select(.headRefName == $b and .state == $s)][0].number // empty'
}
section() {  # title quota — a counted heading, then at most quota of the lines on stdin
  local n=0 body='' line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$((n + 1)); [ "$n" -gt "$2" ] || body="$body$(ds_clean "$line" | cut -c 1-110)
"
  done
  printf '## %s (%s)\n%s' "$1" "$n" "$body"
  [ "$n" -le "$2" ] || echo "... and $((n - $2)) more"
}
workers() {  # one line per recorded worker
  local f id state since
  for f in "$st"/workers/*.meta; do
    [ -f "$f" ] || continue
    id=$(basename "$f" .meta); state=; since=
    [ ! -f "$st/workers/$id.state" ] || read -r state since _ < "$st/workers/$id.state"
    case $since in ''|*[!0-9]*) since=$now ;; esac
    echo "$id #$(get issue "$id") $(get kind "$id") ${state:-unconfirmed}" \
      "$(age $((now - since))) $(get branch "$id") PR #$(pr_of "$(get branch "$id")" OPEN)"
  done | sed 's/ PR #$//'
}
accounting() {  # every start since the last stage report, with its end
  local since epoch id issue kind branch pr state n=0
  since=$(cat "$st/stage-report" 2>/dev/null); case $since in ''|*[!0-9]*) since=0 ;; esac
  [ -f "$st/starts" ] || return 0
  while read -r epoch id issue kind branch; do
    n=$((n + 1))
    case $epoch in ''|*[!0-9]*) continue ;; esac
    [ "$epoch" -gt "$since" ] || continue
    pr=$(pr_of "$branch" MERGED)
    state=$(cut -d' ' -f1 "$st/workers/$id.state" 2>/dev/null)
    if awk -v n="$n" -v i="$issue" 'NR > n && $3 == i { f = 1 } END { exit !f }' "$st/starts"
    then echo "$id #$issue replaced by a later start"
    elif [ -n "$pr" ]; then echo "$id #$issue landed (PR #$pr)"
    elif [ -f "$st/workers/$id.meta" ] && case $state in busy|idle) true ;; *) false ;; esac
    then echo "$id #$issue running"
    elif [ ! -f "$st/workers/$id.meta" ] && [ "$kind" = scout ]; then echo "$id #$issue ended"
    elif [ ! -f "$st/workers/$id.meta" ] && [ "$(printf '%s' "$issues" | jq -r --argjson n \
      "$issue" '[.[] | select(.number == $n)][0].state // empty')" = CLOSED ]; then
      echo "$id #$issue absorbed (issue closed, no PR of its own landed)"
    elif [ -f "$st/workers/$id.meta" ]; then
      echo "! $id #$issue session ${state:-unconfirmed}, not landed: relaunch it or replace it"
    else echo "! $id #$issue UNACCOUNTED: no records, not landed, issue not closed"
    fi
  done < "$st/starts"
}

pid=$(cat "$st/watch.lock/pid" 2>/dev/null)
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ -n "$(find "$st/watch.beat" -mmin -5 \
  2>/dev/null)" ]; then watcher="armed (pid $pid)"; else watcher="NOT ARMED"; fi
queued=0; [ ! -f "$st/wake-queue" ] || queued=$(grep -c . "$st/wake-queue")
ask='any(.labels[]?; .name == "ask")'
{
  echo "# Board: ${repo:-?}, $(date '+%Y-%m-%d %H:%M'). Rendered from records; edits are lost."
  echo "watcher: $watcher   wakes waiting: $queued"
  [ "$rc" -eq 0 ] || echo "! GitHub could not be read: issues, PRs, and worker ends are incomplete"
  printf '%s' "$issues" | jq -r ".[] | select(.state == \"OPEN\" and $ask)
    | \"#\(.number) \(.title)\"" | section "Asks open" 6
  workers | section "Workers in flight" 12
  accounting | section "Started since the last stage report" 14
  printf '%s' "$prs" | jq -r '.[] | select(.state == "OPEN") | "#\(.number) \(.title)" +
    " (\(.headRefName))" + (if .isDraft then " draft" else "" end)' | section "PRs open" 14
  printf '%s' "$issues" | jq -r ".[] | select(.state == \"OPEN\" and ($ask | not))
    | \"#\(.number) \(.title)\"" | section "Issues open" 20
} > "$st/board.tmp"
mv "$st/board.tmp" "$(dirname "$st")/board.md" && cat "$(dirname "$st")/board.md"
exit "$rc"
