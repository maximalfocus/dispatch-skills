#!/usr/bin/env bash
# test-turnend-guard.sh — hermetic tests for turnend-guard.sh: a temporary project with
# hand-written worker and watcher records. No network. Exit 0 when every case passes.
set -u
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(cd "$(mktemp -d)" && pwd -P)
pass=0; fail=0
ok() { pass=$((pass + 1)); }
no() { fail=$((fail + 1)); echo "FAIL: $*"; }
check() { if eval "$2"; then ok; else no "$1 (rc=$rc out=$out)"; fi; }

unset DISPATCH_STATE DISPATCH_WORKER DISPATCH_ROLE DS_LOCK_TRIES
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export DISPATCH_GUARD_WAIT=0
repo="$tmp/project"; git init -q -b main "$repo"; git -C "$repo" commit -q --allow-empty -m base
git -C "$repo" worktree add -q -b w "$tmp/wt" main 2>/dev/null
st="$repo/.dispatch/state"; mkdir -p "$st/workers"
sleep 300 & live=$!
trap 'kill "$live" 2>/dev/null; wait 2>/dev/null; rm -rf "$tmp"' EXIT
guard() { out=$(cd "${dir:-$repo}" && echo '{"hook_event_name":"Stop"}' |
  "$here/turnend-guard.sh" 2>&1); rc=$?; }
says() { printf '%s' "$out" | grep -q -- "$1"; }
arm() {  # [pid] — a watcher lock held by that pid, and a fresh beacon
  mkdir -p "$st/watch.lock"; echo "${1:-$live}" > "$st/watch.lock/pid"; touch "$st/watch.beat"
}
disarm() { rm -rf "$st/watch.lock" "$st/watch.beat"; }

# 1. Nothing in flight: the turn may end, armed or not.
guard; check "no workers, no block" '[ "$rc" -eq 0 ] && [ -z "$out" ]'

# 2. Work in flight and nothing armed: blocked with the repair line, at most 3 times.
echo "issue=7" > "$st/workers/w7.meta"
guard; check "in flight and unarmed blocks" \
  '[ "$rc" -eq 2 ] && says "no watcher is armed" && says "block 1 of 3" && says "watch.sh"'
guard; guard; check "the third block" '[ "$rc" -eq 2 ] && says "block 3 of 3"'
guard; check "the fourth stop is allowed, loudly" \
  '[ "$rc" -eq 0 ] && says "TURN ENDED BLIND" && says "\"systemMessage\""'
guard; check "the count starts again" '[ "$rc" -eq 2 ] && says "block 1 of 3"'

# 3. A live watcher with a fresh beacon is armed.
arm; guard; check "armed lets the turn end" '[ "$rc" -eq 0 ] && [ -z "$out" ]'
check "a clean stop resets the count" '[ ! -e "$st/turnend.blocks" ]'
rm "$st/workers/w7.meta"; echo "busy 1 7" > "$st/workers/w7.state"; disarm
guard; check "a state file alone is work in flight" '[ "$rc" -eq 2 ]'
arm 999999; guard; check "a dead watcher pid is not armed" '[ "$rc" -eq 2 ]'
arm; touch -t 202001010000 "$st/watch.beat"
guard; check "a stale beacon is not armed" '[ "$rc" -eq 2 ]'
rm -rf "$st/watch.lock"; touch "$st/watch.beat"
guard; check "a beacon with no watcher is not armed" '[ "$rc" -eq 0 ] && says "BLIND"'

# 4. The watcher that autoarm starts at the same Stop is waited for.
disarm; rm -f "$st/turnend.blocks"; ( sleep 1; arm ) &
out=$(cd "$repo" && DISPATCH_GUARD_WAIT=4 "$here/turnend-guard.sh" </dev/null 2>&1); rc=$?
check "a watcher that arms a moment later is seen" '[ "$rc" -eq 0 ] && [ -z "$out" ]'

# 5. Wakes waiting: the repair is to handle them.
disarm; printf '1\t1\thandback\tk\tHANDBACK x\n' > "$st/wake-queue"
guard; check "queued wakes name drain.sh" \
  '[ "$rc" -eq 2 ] && says "wakes are waiting" && says "drain.sh"'
rm -f "$st/wake-queue" "$st/turnend.blocks"

# 6. Inert outside the dispatcher's session.
out=$(cd "$repo" && DISPATCH_ROLE=aide "$here/turnend-guard.sh" </dev/null 2>&1); rc=$?
check "the aide's session is not guarded" '[ "$rc" -eq 0 ] && [ -z "$out" ]'
out=$(cd "$repo" && DISPATCH_WORKER=w7 "$here/turnend-guard.sh" </dev/null 2>&1); rc=$?
check "a worker's session is not guarded" '[ "$rc" -eq 0 ] && [ -z "$out" ]'
dir="$tmp/wt"; guard; check "a worker's worktree is not guarded" '[ "$rc" -eq 0 ] && [ -z "$out" ]'
dir="$tmp"; guard; check "outside a project it does nothing" '[ "$rc" -eq 0 ] && [ -z "$out" ]'
dir=; out=$(cd "$repo" && DISPATCH_ROLE=dispatcher "$here/turnend-guard.sh" </dev/null 2>&1); rc=$?
check "the dispatcher's own role is guarded" '[ "$rc" -eq 2 ]'

echo "test-turnend-guard: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
