#!/usr/bin/env bash
# drain.sh — read the wake queue, and acknowledge wakes only after handling them (DESIGN.md §12),
# so a session that dies mid-handling sees the same wakes again instead of losing them.
#
#   drain.sh                     print queued wakes, oldest first; exit 0, or 124 when empty
#   drain.sh --ack-through SEQ   remove every wake with seq <= SEQ
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"
st=$(ds_state) || exit 1

case "${1:-}" in
  "")
    ds_print_queue "$st" || exit 124 ;;
  --ack-through)
    seq=${2:-}
    case $seq in ''|*[!0-9]*) echo "drain: --ack-through needs a number" >&2; exit 1 ;; esac
    ds_lock "$st/queue.lock" || exit 1
    if [ -f "$st/wake-queue" ]; then
      awk -F'\t' -v s="$seq" '$2 > s' "$st/wake-queue" > "$st/wake-queue.tmp" &&
        mv "$st/wake-queue.tmp" "$st/wake-queue"
    fi
    ds_unlock "$st/queue.lock"
    left=$(wc -l < "$st/wake-queue" 2>/dev/null | tr -d ' ')
    echo "acknowledged through $seq; ${left:-0} left" ;;
  *)
    echo "usage: drain.sh [--ack-through SEQ]" >&2; exit 1 ;;
esac
