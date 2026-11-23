#!/usr/bin/env bash
# turnend-guard.sh — never end a turn blind (DESIGN.md §12). A Stop hook for the dispatcher's
# session: if work is in flight and nothing is armed to wake the dispatcher, it blocks the stop
# (exit 2) with the line that repairs it.
#
#   turnend-guard.sh        the hook; the agent's Stop payload on stdin is not needed
#
# In flight: a worker record exists (workers/<id>.meta or .state; teardown.sh removes them).
# Armed: the watcher's lock names a live pid and its beacon is younger than 5 minutes. The hook
# waits up to DISPATCH_GUARD_WAIT (5) seconds for that, since autoarm.sh starts the watcher at the
# same Stop.
# It blocks at most 3 times in a row; then it allows the stop and says so loudly, so a watcher that
# cannot start never traps the session. The count resets when a stop is clean.
# Inert (exit 0) in a worker's session or worktree, and in a session whose DISPATCH_ROLE is not
# the dispatcher's.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"
case ${DISPATCH_ROLE:-dispatcher} in dispatcher) ;; *) exit 0 ;; esac
[ -z "${DISPATCH_WORKER:-}" ] || exit 0
gd=$(git rev-parse --git-dir 2>/dev/null) || exit 0  # not a project: nothing to guard
[ "$(cd "$gd" && pwd -P)" = "$(cd "$(git rev-parse --git-common-dir)" && pwd -P)" ] || exit 0
st=$(ds_state 2>/dev/null) || exit 0

flight=0
for f in "$st"/workers/*.meta "$st"/workers/*.state; do
  [ -f "$f" ] || continue
  flight=1; break
done
armed() {  # a live watcher with a fresh beacon
  local pid
  pid=$(cat "$st/watch.lock/pid" 2>/dev/null)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null &&
    [ -n "$(find "$st/watch.beat" -mmin -5 2>/dev/null)" ]
}
wait=${DISPATCH_GUARD_WAIT:-5}; case $wait in ''|*[!0-9]*) wait=5 ;; esac
i=0
if [ "$flight" -eq 1 ]; then
  until armed || [ "$i" -ge $((wait * 5)) ]; do i=$((i + 1)); sleep 0.2; done
fi
if [ "$flight" -eq 0 ] || armed; then rm -f "$st/turnend.blocks"; exit 0; fi

n=$(cat "$st/turnend.blocks" 2>/dev/null); case $n in ''|*[!0-9]*) n=0 ;; esac
if [ "$n" -ge 3 ]; then
  rm -f "$st/turnend.blocks"
  msg="dispatch: TURN ENDED BLIND. Workers are in flight and no watcher is armed; the stop was"
  msg="$msg blocked 3 times and is now allowed. Nothing will wake the dispatcher."
  echo "$msg" >&2
  jq -n --arg m "$msg" '{systemMessage: $m}' 2>/dev/null
  exit 0
fi
echo $((n + 1)) > "$st/turnend.blocks"
if [ -s "$st/wake-queue" ]; then  # the watcher stops while wakes wait: handling them is the repair
  echo "dispatch: wakes are waiting and workers are in flight (block $((n + 1)) of 3). Run" \
    "$here/drain.sh, handle each wake, acknowledge it, and then end the turn." >&2
  exit 2
fi
echo "dispatch: workers are in flight and no watcher is armed, so nothing would wake you" \
  "(block $((n + 1)) of 3). Arm it before the turn ends: run $here/watch.sh in the background," \
  "or, where the runtime cannot wake an idle session, call $here/autoarm.sh --checkpoint" >&2
exit 2
