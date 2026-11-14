#!/usr/bin/env bash
# watch.sh — wake the dispatcher on facts, never on screens (DESIGN.md §12). Run it inside the
# project checkout; one watcher per project.
#
#   watch.sh [--once] [--seconds N]
#
# Wakes (each queued once, by key):
#   handback  a new comment line starting "HANDBACK "        key comment:<id>
#   verdict   a new comment line starting "ACCEPT "          key comment:<id>
#   head      a handed-back PR whose live head moved on      key head:<pr>:<sha>
#   idle      a worker idle ≥ DISPATCH_IDLE_SECS (300) with no hand-back in the 5 min before it
#             went idle; worker files are workers/<id>.state = "<busy|idle> <epoch> <issue>"
#   error     GitHub unreachable for 20 polls in a row       key error:github:<hour>
# Exit: 0 wakes queued (printed with the ack command) · 124 quiet until --once or --seconds ran
#       out · 3 another watcher holds this project · 1 error.
# Env: DISPATCH_POLL (15 s), DISPATCH_IDLE_SECS, DISPATCH_REPO (owner/name), DISPATCH_GH (gh).
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"

once=0; seconds=0
while [ $# -gt 0 ]; do
  case $1 in
    --once) once=1 ;;
    --seconds) seconds=${2:?--seconds needs a value}; shift ;;
    *) echo "usage: watch.sh [--once] [--seconds N]" >&2; exit 1 ;;
  esac
  shift
done
poll=${DISPATCH_POLL:-15}; idle_after=${DISPATCH_IDLE_SECS:-300}; gh=${DISPATCH_GH:-gh}
case $seconds$poll$idle_after in
  *[!0-9]*) echo "watch: --seconds, DISPATCH_POLL, DISPATCH_IDLE_SECS need whole numbers" >&2
    exit 1 ;;
esac
command -v jq >/dev/null || { echo "watch: jq is required" >&2; exit 1; }
st=$(ds_state) || exit 1
repo=${DISPATCH_REPO:-$($gh repo view --json nameWithOwner --jq .nameWithOwner)} || exit 1

lock="$st/watch.lock"
if ! mkdir "$lock" 2>/dev/null; then
  i=0  # a fresh holder writes its pid within microseconds: wait rather than steal its lock
  while [ ! -s "$lock/pid" ] && [ "$i" -lt 20 ]; do sleep 0.1; i=$((i + 1)); done
  holder=$(cat "$lock/pid" 2>/dev/null)
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    echo "watch: already running for this project (pid $holder)" >&2; exit 3
  fi
  rm -rf "$lock"  # the holder is provably gone
  mkdir "$lock" 2>/dev/null || { echo "watch: lost the race for the watcher lock" >&2; exit 3; }
fi
echo $$ > "$lock/pid"
trap 'rm -rf "$lock"' EXIT
trap 'exit 130' INT TERM

poll_comments() {  # queue HANDBACK/ACCEPT lines; record hand-backs tab-separated, then the epoch
  local since json latest rows id line url issue pr sha
  since=$(cat "$st/gh-since" 2>/dev/null)
  if [ -z "$since" ]; then  # first run: start from now, never replay history
    date -u +%Y-%m-%dT%H:%M:%SZ > "$st/gh-since"; return 0
  fi
  json=$($gh api \
    "repos/$repo/issues/comments?since=$since&sort=updated&direction=asc&per_page=100") || return 1
  printf '%s' "$json" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
  # odd JSON must fail here, before the cursor moves, or that comment's hand-back is lost.
  rows=$(printf '%s' "$json" | jq -r '.[] | . as $c
      | (.body | if type == "string" then . else "" end) as $body
      | [$body | split("\n")[] | sub("\r$"; "") | select(test("^(HANDBACK|ACCEPT) "))][0] // empty
      | [($c.id | tostring), ., (($c.html_url // "") | tostring)] | @tsv') || return 1
  [ -z "$rows" ] ||
  printf '%s\n' "$rows" |
  while IFS=$'\t' read -r id line url; do
    case $line in
      HANDBACK*)
        if ! grep -qxF "comment:$id" "$st/seen" 2>/dev/null; then
          issue=$(printf '%s' "$line" | sed -n 's/.*issue=#\([0-9]*\).*/\1/p')
          pr=$(printf '%s' "$line" | sed -n 's/.*pr=#\([0-9]*\).*/\1/p')
          sha=$(printf '%s' "$line" | sed -n 's/.*head=\([0-9a-fA-F]*\).*/\1/p')
          printf '%s\t%s\t%s\t%s\n' "$issue" "$pr" "$sha" "$(date +%s)" >> "$st/handbacks"
        fi
        ds_enqueue "$st" handback "comment:$id" "$line $url" ;;
      *) ds_enqueue "$st" verdict "comment:$id" "$line $url" ;;
    esac
  done
  latest=$(printf '%s' "$json" | jq -r 'map(.updated_at | if type == "string" then . else "" end)
    | max // empty')
  [ -z "$latest" ] || echo "$latest" > "$st/gh-since"
}

poll_heads() {  # a handed-back PR whose live head is not the handed-back head must not land
  local json pr sha handed
  [ -s "$st/handbacks" ] || return 0
  json=$($gh api "repos/$repo/pulls?state=open&per_page=100") || return 1
  printf '%s' "$json" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
  printf '%s' "$json" | jq -r '.[] | select(.head.sha) | "\(.number) \(.head.sha)"' |
  while read -r pr sha; do
    handed=$(awk -F'\t' -v p="$pr" '$2 == p { h = $3 } END { print h }' "$st/handbacks")
    [ -n "$handed" ] || continue
    case $sha in "$handed"*) continue ;; esac
    ds_enqueue "$st" head "head:$pr:$sha" "PR #$pr head moved to $sha after hand-back at $handed"
  done
}

poll_workers() {
  local f id state since issue now recent
  now=$(date +%s)
  for f in "$st"/workers/*.state; do
    [ -f "$f" ] || continue
    id=$(basename "$f" .state); read -r state since issue < "$f"
    [ "$state" = idle ] && [ -n "$since" ] || continue
    case $since in *[!0-9]*)  # a half-written file must not kill the watcher
      echo "watch: skipping $f: no idle epoch in '$since'" >&2; continue ;; esac
    [ $((now - since)) -ge "$idle_after" ] || continue
    recent=$(awk -F'\t' -v i="$issue" -v s="$since" '$1 == i && $4 + 0 >= s - 300 { n++ }
      END { print n+0 }' "$st/handbacks" 2>/dev/null || echo 0)
    [ "${recent:-0}" -eq 0 ] || continue
    ds_enqueue "$st" idle "idle:$id:$since" "worker $id (issue #${issue:-?}) idle with no hand-back"
  done
}

# Wakes left from a run that ended before they were acknowledged come first.
ds_print_queue "$st" && exit 0

start=$(date +%s); fails=0
while :; do
  touch "$st/watch.beat"
  if poll_comments && poll_heads; then
    fails=0
  else
    fails=$((fails + 1))
    echo "watch: GitHub poll failed ($fails in a row)" >&2
    [ "$fails" -lt 20 ] ||
      ds_enqueue "$st" error "error:github:$(date +%Y%m%d%H)" "GitHub unreachable for $fails polls"
  fi
  poll_workers
  ds_print_queue "$st" && exit 0
  [ "$once" -eq 0 ] || exit 124
  if [ "$seconds" -gt 0 ] && [ $(( $(date +%s) - start )) -ge "$seconds" ]; then exit 124; fi
  sleep "$poll"
done
