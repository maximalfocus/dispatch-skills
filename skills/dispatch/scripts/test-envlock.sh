#!/usr/bin/env bash
# test-envlock.sh — hermetic tests for envlock.sh: a temporary git repo with a linked worktree,
# and real short-lived processes as holders. No network. Exit 0 when every case passes.
set -u
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(cd "$(mktemp -d)" && pwd -P)
pass=0; fail=0
ok() { pass=$((pass + 1)); }
no() { fail=$((fail + 1)); echo "FAIL: $*"; }
check() { if eval "$2"; then ok; else no "$1 (rc=$rc out=$out)"; fi; }

unset DISPATCH_STATE DS_LOCK_TRIES
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
repo="$tmp/project"; git init -q -b main "$repo"
git -C "$repo" commit -q --allow-empty -m base
git -C "$repo" worktree add -q -b exec "$tmp/exec" main 2>/dev/null
locks="$repo/.dispatch/state/envlocks"
sleep 300 & a=$!; sleep 300 & b=$!
trap 'kill "$a" "$b" 2>/dev/null; wait 2>/dev/null; rm -rf "$tmp"' EXIT
envlock() { out=$(cd "$repo" && "$here/envlock.sh" "$@" 2>&1); rc=$?; }
says() { printf '%s' "$out" | grep -q -- "$1"; }

# 1. One holder: the first acquire wins, the second gets 75 and the holder's line.
envlock status staging
check "a new environment is free" '[ "$rc" -eq 0 ] && says "free env=staging"'
envlock acquire staging --pid "$a" --role aide --issue "#12"
check "acquire takes a free environment" '[ "$rc" -eq 0 ] && says "acquired env=staging pid=$a"'
check "the holder file is pid, role, issue, since" \
  'grep -qE "^$a aide 12 [0-9]+\$" "$locks/staging"'
since=$(cut -d' ' -f4 "$locks/staging")
envlock acquire staging --pid "$b" --role executor
check "a second holder gets 75" '[ "$rc" -eq 75 ] && says "held env=staging pid=$a role=aide"'
check "and does not change the holder" 'grep -q "^$a aide 12 $since\$" "$locks/staging"'
envlock status staging; check "status reports held with 75" '[ "$rc" -eq 75 ] && says "issue=12"'
envlock acquire staging --pid "$a" --role other
check "the holder acquiring again keeps its lock" \
  '[ "$rc" -eq 0 ] && says "already held" && grep -q "^$a aide 12 $since\$" "$locks/staging"'

# 2. Every worktree of the project sees the same lock.
out=$(cd "$tmp/exec" && "$here/envlock.sh" acquire staging --pid "$b" 2>&1); rc=$?
check "a linked worktree sees the holder" '[ "$rc" -eq 75 ] && says "pid=$a"'
check "and keeps no state of its own" '[ ! -e "$tmp/exec/.dispatch" ]'
check "state stays out of git" '[ -z "$(git -C "$repo" status --porcelain)" ]'

# 3. Only the holder releases; environments are independent.
envlock release staging --pid "$b"
check "another process cannot release" '[ "$rc" -eq 75 ] && [ -f "$locks/staging" ]'
envlock acquire db --pid "$b" --role executor
check "another environment is independent" '[ "$rc" -eq 0 ] && says "acquired env=db pid=$b"'
envlock status
check "status with no name lists every lock" \
  '[ "$rc" -eq 0 ] && says "held env=staging pid=$a" && says "held env=db pid=$b role=executor"'
envlock release staging --pid "$a"
check "the holder releases" '[ "$rc" -eq 0 ] && says "released" && [ ! -e "$locks/staging" ]'
envlock release staging --pid "$a"; check "releasing a free lock is fine" \
  '[ "$rc" -eq 0 ] && says "not held"'
envlock acquire staging --pid "$b"
check "a released environment can be taken" '[ "$rc" -eq 0 ] && says "pid=$b"'

# 4. Reclaim only when the holder's pid is provably gone.
kill "$b"; wait "$b" 2>/dev/null
envlock status staging
check "a dead holder shows as stale, not held" '[ "$rc" -eq 0 ] && says "stale"'
envlock acquire staging --pid "$a"
check "a dead holder's lock is reclaimed" \
  '[ "$rc" -eq 0 ] && says "reclaiming staging from pid $b" && says "acquired env=staging pid=$a"'
envlock acquire db --pid "$b"
check "a dead process cannot become a holder" '[ "$rc" -eq 1 ] && says "not running"'
echo garbage > "$locks/odd"; envlock acquire odd --pid "$a"
check "an unreadable lock counts as held" '[ "$rc" -eq 75 ] && grep -q garbage "$locks/odd"'

# 5. The default holder is the calling session, not the short-lived shell that ran the command.
out=$(cd "$repo" && bash -c "'$here/envlock.sh' acquire auto; echo shell=\$\$" 2>&1); rc=$?
holder=$(cut -d' ' -f1 "$locks/auto" 2>/dev/null)
shell=$(printf '%s' "$out" | sed -n 's/^shell=//p')
check "the default holder outlives the command's shell" \
  '[ -n "$holder" ] && [ "$holder" != "$shell" ] && ps -p "$holder" >/dev/null'
envlock release auto; check "and the same session releases it" '[ "$rc" -eq 0 ] && says released'

# 6. Usage errors, and a name that could leave the lock directory.
envlock acquire; check "acquire needs a name" '[ "$rc" -eq 1 ]'
envlock acquire ../x --pid "$a"; check "a path is not a name" '[ "$rc" -eq 1 ]'
envlock acquire .mutex --pid "$a"; check "a dot name is refused" '[ "$rc" -eq 1 ]'
envlock acquire e --pid "$a" --issue x; check "a bad issue is usage" '[ "$rc" -eq 1 ]'
envlock frob e; check "an unknown command is usage" '[ "$rc" -eq 1 ]'

# 7. Two racers, one winner.
for p in 1 2 3 4 5 6; do
  ( cd "$repo" && "$here/envlock.sh" acquire race --pid "$a" >/dev/null 2>&1
    echo $? >> "$tmp/race" ) &
done
( cd "$repo" && "$here/envlock.sh" acquire race --pid $$ >/dev/null 2>&1; echo $? >> "$tmp/race" ) &
wait $(jobs -p | grep -v "^$a\$") 2>/dev/null
check "racing holders never both win" \
  '[ "$(wc -l < "$locks/race")" -eq 1 ] && [ "$(grep -c . "$tmp/race")" -eq 7 ]'
winner=$(cut -d' ' -f1 "$locks/race")
if [ "$winner" = "$a" ]; then want=1; else want=6; fi
check "the losers all got 75" '[ "$(grep -c "^75\$" "$tmp/race")" -eq "$want" ]'

echo "test-envlock: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
