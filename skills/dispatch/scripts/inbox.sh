#!/usr/bin/env bash
# inbox.sh — steer a worker through files, never by typing instructions into its terminal
# (DESIGN.md §12). Run it anywhere in the project.
#
#   inbox.sh send <id> <message...> | --file <file>   queue a message for that worker, ring it
#   inbox.sh ack <NNN> [--id <id>]    the worker's: message NNN is handled ($DISPATCH_WORKER)
#   inbox.sh list <id>                the unread messages
#   inbox.sh tick                     ring whoever is due; watch.sh calls this on every poll
#
# A message is the file inbox/<id>/NNN.msg, written whole by a rename; a number is used once.
# The terminal only ever receives one constant line that names the inbox. A ring goes to a live
# terminal whose worker is not busy: once when due, then again every DISPATCH_RING_SECS (90) up
# to 3 more times while the oldest message stays unread; after that the dispatcher gets one
# `inbox` wake. A busy worker is rung when its turn ends; a dead terminal is never rung and wakes
# the dispatcher at once.
# Exit: 0 done · 1 usage, an unknown worker, or a message that is not there.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"
# shellcheck source=runtime.sh
. "$here/runtime.sh"
die() { echo "inbox: $*" >&2; exit 1; }
usage() { die "usage: inbox.sh send <id> <message...>|--file <file> | ack <NNN> [--id <id>]" \
  "| list <id> | tick"; }
st=$(ds_state) || exit 1
okid() { case $1 in ''|.*|*[!A-Za-z0-9._-]*) usage ;; esac; }
unread() { ls "$st/inbox/$1" 2>/dev/null | grep '^[0-9]\{1,\}\.msg$' | sort -n; }
get() { sed -n "s/^$1=//p" "$st/workers/$2.meta" 2>/dev/null | head -n 1; }

ring() {  # id — one ring if the rules allow it, or the one wake when ringing is over
  local id=$1 dir="$st/inbox/$1" n rmsg count last woke state now
  n=$(unread "$id" | head -n 1); n=${n%.msg}
  [ -n "$n" ] || { rm -f "$dir/.ring"; return 0; }
  rmsg=; count=0; last=0; woke=0
  [ ! -f "$dir/.ring" ] || read -r rmsg count last woke < "$dir/.ring"
  [ "$rmsg" = "$n" ] || { count=0; last=0; woke=0; }
  [ "$woke" != 1 ] || return 0
  now=$(date +%s)
  if ! rt_alive "$(get term "$id")" "$(get handle "$id")"; then
    ds_enqueue "$st" inbox "inbox:$id:$n" "worker $id's terminal is gone; message $n is unread"
    woke=1
  elif [ "$count" -ge 4 ]; then
    ds_enqueue "$st" inbox "inbox:$id:$n" "worker $id left message $n unread after 3 re-rings"
    woke=1
  else
    state=$(cut -d' ' -f1 "$st/workers/$id.state" 2>/dev/null)
    [ "$state" != busy ] || return 0
    [ $((now - last)) -ge "${DISPATCH_RING_SECS:-90}" ] || return 0
    rt_type "$(get term "$id")" "$(get handle "$id")" "dispatch inbox: read each .msg file in \
$dir in order, act on it, then run: $here/inbox.sh ack <its number>" || return 0
    count=$((count + 1)); last=$now
  fi
  echo "$n $count $last $woke" > "$dir/.ring"
}

cmd=${1:-}; [ $# -eq 0 ] || shift
case $cmd in
  send)
    id=${1:-}; okid "$id"; shift
    [ -f "$st/workers/$id.meta" ] || die "no worker $id is recorded here"
    dir="$st/inbox/$id"; mkdir -p "$dir/read"
    if [ "${1:-}" = --file ]; then
      [ -r "${2:-}" ] || die "cannot read ${2:-the message file}"
      text=$(cat "$2")
    else
      text=$*
    fi
    [ -n "$text" ] || die "an empty message"
    ds_lock "$dir/.lock" || exit 1
    n=$(( $(cat "$dir/.seq" 2>/dev/null || echo 0) + 1 ))
    name=$(printf '%03d' "$n")
    printf '%s\n' "$text" > "$dir/.$name.tmp" && mv "$dir/.$name.tmp" "$dir/$name.msg" &&
      echo "$n" > "$dir/.seq"
    rc=$?; ds_unlock "$dir/.lock"; [ "$rc" -eq 0 ] || die "could not write the message"
    ring "$id"; echo "queued $id $name" ;;
  ack)
    n=${1:-}; id=${DISPATCH_WORKER:-}
    [ "${2:-}" != --id ] || id=${3:-}
    okid "$id"; case $n in ''|*[!0-9]*) usage ;; esac
    name=$(printf '%03d' "$((10#$n))")
    mv "$st/inbox/$id/$name.msg" "$st/inbox/$id/read/$name.msg" 2>/dev/null ||
      die "no unread message $name for $id"
    echo "acknowledged $id $name" ;;
  list) okid "${1:-}"; unread "$1" ;;
  tick)
    for d in "$st"/inbox/*/; do
      [ -d "$d" ] || continue
      ring "$(basename "$d")"
    done ;;
  *) usage ;;
esac
