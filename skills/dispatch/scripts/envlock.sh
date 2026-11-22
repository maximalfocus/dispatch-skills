#!/usr/bin/env bash
# envlock.sh — one holder per test environment (DESIGN.md §12). Run it anywhere in the project:
# the locks live in the project's one state dir, so every worktree sees the same holder.
#
#   envlock.sh acquire <env> [--role <role>] [--issue <n>] [--pid <pid>]
#   envlock.sh release <env> [--pid <pid>]
#   envlock.sh status [<env>]
#
# The holder is a process: by default the session that called us (the nearest ancestor that is not
# a shell), or --pid. The lock file envlocks/<env> is one line: "<pid> <role> <issue> <since>".
#   acquire  0 taken, or already ours · 75 held by another live process (its line is printed)
#   release  0 released, or not held · 75 held by another live process
#   status   0 free or stale · 75 held; with no <env>, one line per lock and exit 0
# A lock is reclaimed only when its holder's pid is provably gone; a live holder is never
# overridden, whoever asks, and a lock file that cannot be read counts as held.
# Exit 1 is a usage or state error.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"
usage() {
  echo "usage: envlock.sh acquire <env> [--role <role>] [--issue <n>] [--pid <pid>]" >&2
  echo "       envlock.sh release <env> [--pid <pid>] | envlock.sh status [<env>]" >&2; exit 1
}

cmd=${1:-}; [ $# -eq 0 ] || shift
env=; role=aide; issue=-; pid=
while [ $# -gt 0 ]; do
  case $1 in
    --role) role=${2:-}; shift ;;
    --issue) issue=${2:-}; shift ;;
    --pid) pid=${2:-}; [ -n "$pid" ] || usage; shift ;;
    -*) usage ;;
    *) [ -z "$env" ] || usage; env=$1 ;;
  esac
  shift
done
issue=${issue#\#}
case $cmd in acquire|release) [ -n "$env" ] || usage ;; status) ;; *) usage ;; esac
case $env in .*|*[!A-Za-z0-9._-]*) usage ;; esac
case $role in ''|*[!A-Za-z0-9._-]*) usage ;; esac
case $issue in -) ;; ''|*[!0-9]*) usage ;; esac
case $pid in *[!0-9]*) usage ;; esac
st=$(ds_state) || exit 1
dir="$st/envlocks"; mkdir -p "$dir" || exit 1

alive() { ps -p "$1" >/dev/null 2>&1; }
caller() {  # the session that called us: the nearest ancestor that is not a shell
  local p=$PPID comm next i=0
  while [ "$i" -lt 10 ]; do
    comm=$(ps -o comm= -p "$p" 2>/dev/null | sed 's/ *$//'); comm=${comm##*/}
    case ${comm#-} in sh|bash|zsh|dash|ksh|fish) ;; *) break ;; esac
    next=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    case $next in ''|0|1|*[!0-9]*) break ;; esac
    p=$next; i=$((i + 1))
  done
  echo "$p"
}
look() {  # env — set hp hr hi hs; return 0 held by a live pid, 1 free, 2 its holder is gone
  hp=; hr=; hi=; hs=
  [ -f "$dir/$1" ] || return 1
  read -r hp hr hi hs < "$dir/$1"
  case $hp in ''|*[!0-9]*) hp=unreadable; return 0 ;; esac
  alive "$hp" && return 0
  return 2
}
line() { echo "$1 env=$2 pid=$hp role=${hr:-?} issue=${hi:-?} since=${hs:-?}"; }

case $cmd in
  status)
    if [ -n "$env" ]; then
      look "$env"; case $? in
        0) line held "$env"; exit 75 ;;
        1) echo "free env=$env" ;;
        *) line "stale (holder gone)" "$env" ;;
      esac
    else
      for f in "$dir"/*; do
        [ -f "$f" ] || continue
        e=$(basename "$f"); look "$e"
        case $? in 0) line held "$e" ;; *) line "stale (holder gone)" "$e" ;; esac
      done
    fi ;;
  acquire|release)
    me=${pid:-$(caller)}
    alive "$me" || { echo "envlock: holder pid $me is not running" >&2; exit 1; }
    ds_lock "$dir/.mutex" || exit 1
    look "$env"; held=$?
    if [ "$held" -eq 0 ] && [ "$hp" != "$me" ]; then
      ds_unlock "$dir/.mutex"; line held "$env"; exit 75
    fi
    if [ "$cmd" = release ]; then
      rm -f "$dir/$env"; ds_unlock "$dir/.mutex"
      [ "$held" -eq 1 ] && echo "not held env=$env" || echo "released env=$env"
    elif [ "$held" -eq 0 ]; then
      ds_unlock "$dir/.mutex"; line "already held" "$env"
    else
      [ "$held" -eq 1 ] || echo "envlock: reclaiming $env from pid $hp, which is gone" >&2
      echo "$me $role $issue $(date +%s)" > "$dir/.$env.tmp" && mv "$dir/.$env.tmp" "$dir/$env"
      rc=$?; ds_unlock "$dir/.mutex"; [ "$rc" -eq 0 ] || exit 1
      look "$env"; line acquired "$env"
    fi ;;
esac
