#!/usr/bin/env bash
# autoarm.sh — arm the watcher whenever the dispatcher's turn ends (DESIGN.md §12).
#
#   autoarm.sh                the Claude Code hook: a Stop hook with "asyncRewake": true. It runs
#                             the watcher in the foreground and exits 2 with the wakes on stderr,
#                             which wakes the idle session.
#   autoarm.sh --checkpoint   where the runtime cannot wake an idle session (Codex): a blocking
#                             call the dispatcher makes before it would stop. Exit 0 with the wakes,
#                             or 124 after DISPATCH_CHECKPOINT_SECS (180) quiet seconds: call again.
#   autoarm.sh --hooks        print the dispatcher's Claude Code hooks: this script, the turn-end
#                             guard, and the role guard
#
# The hook stops the watcher after DISPATCH_ARM_SECS (21600), before the hook's own timeout, and
# then wakes the session once to re-arm: an idle session is never left with nothing armed. Only
# asyncRewake wakes an idle session; a plain async hook's output waits for the next user turn.
# A watcher already running for this project (exit 3) needs no second one. A watcher that fails
# wakes the session with the reason, at most 3 times in a row; after that turnend-guard.sh speaks.
# Inert in a worker's session and in a session whose DISPATCH_ROLE is not the dispatcher's.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"
# shellcheck source=runtime.sh
. "$here/runtime.sh"
arm=${DISPATCH_ARM_SECS:-21600}; case $arm in ''|*[!0-9]*) arm=21600 ;; esac

case ${1:-} in
  --hooks)
    jq -n --arg a "$(rt_sq "$here/autoarm.sh")" --arg t "$(rt_sq "$here/turnend-guard.sh")" \
      --arg g "$(rt_sq "$here/role-guard.sh")" --argjson s "$arm" '{hooks: {
        Stop: [{hooks: [{type: "command", command: $t},
          {type: "command", command: $a, asyncRewake: true, timeout: ($s + 120)}]}],
        PreToolUse: [{hooks: [{type: "command", command: $g}]}]}}'
    exit ;;
  --checkpoint)
    "$here/watch.sh" --seconds "${DISPATCH_CHECKPOINT_SECS:-180}"; rc=$?
    [ "$rc" -ne 124 ] || echo "quiet: nothing to handle yet; call the checkpoint again"
    exit "$rc" ;;
  '') ;;
  *) echo "usage: autoarm.sh [--checkpoint | --hooks]" >&2; exit 1 ;;
esac

case ${DISPATCH_ROLE:-dispatcher} in dispatcher) ;; *) exit 0 ;; esac
[ -z "${DISPATCH_WORKER:-}" ] || exit 0
st=$(ds_state 2>/dev/null) || exit 0
out=$("$here/watch.sh" --seconds "$arm" 2>"$st/autoarm.err"); rc=$?
case $rc in
  0) rm -f "$st/autoarm.fails"
    { echo "dispatch: the watcher has wakes for you. Handle each, then acknowledge with" \
        "$here/drain.sh --ack-through <seq>."
      printf '%s\n' "$out"; } >&2
    exit 2 ;;
  124) rm -f "$st/autoarm.fails"
    echo "dispatch: watcher checkpoint: nothing happened in $arm s. Nothing to handle; end" \
      "the turn again to re-arm the watcher." >&2
    exit 2 ;;
  3) exit 0 ;;
esac
n=$(cat "$st/autoarm.fails" 2>/dev/null); case $n in ''|*[!0-9]*) n=0 ;; esac
[ "$n" -lt 3 ] || exit 0
echo $((n + 1)) > "$st/autoarm.fails"
{ echo "dispatch: the watcher could not run (exit $rc), so nothing is armed:"
  tail -n 5 "$st/autoarm.err"; } >&2
exit 2
