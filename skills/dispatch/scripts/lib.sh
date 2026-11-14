# lib.sh — helpers shared by the dispatch runtime scripts. Sourced, never run. Bash 3.2-safe.
# State lives in <project>/.dispatch/state (override: DISPATCH_STATE) and is excluded from git
# locally through .git/info/exclude, so it never reaches a commit.

ds_state() {  # print the state dir, creating it and its git exclusion on first use
  local root dir common
  root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "dispatch: run inside the project's git checkout" >&2; return 1; }
  dir="${DISPATCH_STATE:-$root/.dispatch/state}"
  mkdir -p "$dir/workers" || return 1
  common=$(cd "$root" && cd "$(git rev-parse --git-common-dir)" && pwd) || return 1
  mkdir -p "$common/info"
  grep -qxF '/.dispatch/' "$common/info/exclude" 2>/dev/null ||
    echo '/.dispatch/' >> "$common/info/exclude"
  printf '%s\n' "$dir"
}

ds_lock() {  # take a short critical-section lock (a directory holding the owner's pid)
  local lock=$1 i=0 holder
  while ! mkdir "$lock" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -ge 50 ]; then  # 5 s: reclaim only when the holder is provably gone
      holder=$(cat "$lock/pid" 2>/dev/null)
      if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
        rm -rf "$lock"; i=0; continue
      fi
      echo "dispatch: lock $lock is held by pid ${holder:-unknown}" >&2; return 1
    fi
    sleep 0.1
  done
  echo $$ > "$lock/pid"
}

ds_unlock() { rm -rf "$1"; }

ds_enqueue() {  # state kind key payload — queue one wake unless its key was already queued
  local st=$1 kind=$2 key=$3 payload seq
  # comment text is untrusted: no tabs/newlines (they are the row), no C0 controls (ANSI
  # escapes would overwrite the dispatcher's own lines), and short enough to stay a fact.
  payload=$(printf '%s' "$4" | tr '\t\n\r' '   ' | LC_ALL=C tr -d '\001-\037\177' | cut -c 1-400)
  ds_lock "$st/queue.lock" || return 1
  if ! grep -qxF -- "$key" "$st/seen" 2>/dev/null; then
    seq=$(( $(cat "$st/wake-seq" 2>/dev/null || echo 0) + 1 ))
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$seq" "$kind" "$key" "$payload" \
      >> "$st/wake-queue"
    echo "$seq" > "$st/wake-seq"
    echo "$key" >> "$st/seen"
    if [ "$(wc -l < "$st/seen")" -gt 6000 ]; then  # keys only need to outlive their events
      tail -n 5000 "$st/seen" > "$st/seen.tmp" && mv "$st/seen.tmp" "$st/seen"
    fi
  fi
  ds_unlock "$st/queue.lock"
}

ds_print_queue() {  # print queued wakes and the ack command; returns 1 when the queue is empty
  local st=$1 last
  [ -s "$st/wake-queue" ] || return 1
  awk -F'\t' '{ printf "wake %s %s %s\n", $2, $3, $5 }' "$st/wake-queue"
  last=$(tail -n 1 "$st/wake-queue" | cut -f2)
  echo "ack after handling: drain.sh --ack-through $last"
}
