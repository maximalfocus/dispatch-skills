#!/usr/bin/env bash
# test-autoarm.sh — hermetic tests for autoarm.sh: a temporary project, a fake gh, and the real
# watch.sh with short timings. No network. Exit 0 when every case passes.
set -u
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(cd "$(mktemp -d)" && pwd -P)
pass=0; fail=0
ok() { pass=$((pass + 1)); }
no() { fail=$((fail + 1)); echo "FAIL: $*"; }
check() { if eval "$2"; then ok; else no "$1 (rc=$rc out=$out)"; fi; }

unset DISPATCH_STATE DISPATCH_WORKER DISPATCH_ROLE DISPATCH_GUARD_CONFIG DISPATCH_TRUSTED_LOGINS \
  DISPATCH_TRUSTED_AUTHORS DISPATCH_IDLE_SECS DS_LOCK_TRIES DISPATCH_CHECKPOINT_SECS \
  CLAUDE_PROJECT_DIR
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
repo="$tmp/project"; fake="$tmp/fake"; mkdir -p "$fake"
git init -q -b main "$repo"; git -C "$repo" commit -q --allow-empty -m base
st="$repo/.dispatch/state"; mkdir -p "$st/workers"
cat > "$fake/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in *api\ user*) echo alice ;; *) echo '[]' ;; esac
EOF
chmod +x "$fake/gh"
export DISPATCH_GH="$fake/gh" DISPATCH_REPO=o/r DISPATCH_POLL=1 DISPATCH_ARM_SECS=1
sleep 300 & live=$!
trap 'kill "$live" 2>/dev/null; wait 2>/dev/null; rm -rf "$tmp"' EXIT
hook() { out=$(cd "$repo" && echo '{"hook_event_name":"Stop"}' | "$here/autoarm.sh" "$@" 2>&1)
  rc=$?; }
says() { printf '%s' "$out" | grep -q -- "$1"; }
wake() { printf '%s\t%s\thandback\tk%s\tHANDBACK issue=#9 pr=#10 head=abc\n' "$(date +%s)" "$1" \
  "$1" >> "$st/wake-queue"; }

# 1. Wakes: the hook exits 2 with them on stderr, which is what wakes the idle session.
(cd "$repo" && "$here/watch.sh" --once >/dev/null 2>&1)  # the first run only sets the cursor
wake 1; out=$(cd "$repo" && "$here/autoarm.sh" </dev/null 2>&1 >/dev/null); rc=$?
check "wakes exit 2 on stderr" \
  '[ "$rc" -eq 2 ] && says "^wake 1 handback HANDBACK issue=#9" && says "drain.sh --ack-through 1"'
hook; check "an unacknowledged wake wakes again" '[ "$rc" -eq 2 ] && says "^wake 1 handback"'
(cd "$repo" && "$here/drain.sh" --ack-through 1 >/dev/null)

# 2. Quiet until the arm time runs out: one wake to re-arm, never a silent idle session.
hook; check "a quiet watcher wakes once to re-arm" \
  '[ "$rc" -eq 2 ] && says "watcher checkpoint" && says "re-arm"'
check "the watcher released its lock" '[ ! -d "$st/watch.lock" ]'

# 3. A watcher already running for the project needs no second one.
mkdir -p "$st/watch.lock"; echo "$live" > "$st/watch.lock/pid"
hook; check "an armed project is left alone" '[ "$rc" -eq 0 ] && [ -z "$out" ]'
rm -rf "$st/watch.lock"

# 4. A watcher that cannot run wakes the session with the reason, 3 times at most.
for i in 1 2 3; do
  out=$(cd "$repo" && DISPATCH_GH=/bin/false DISPATCH_REPO=o/r "$here/autoarm.sh" </dev/null 2>&1)
  rc=$?
done
check "a failing watcher wakes with the reason" \
  '[ "$rc" -eq 2 ] && says "could not run (exit 1)" && says "DISPATCH_TRUSTED_LOGINS"'
out=$(cd "$repo" && DISPATCH_GH=/bin/false "$here/autoarm.sh" </dev/null 2>&1); rc=$?
check "the fourth failure in a row is silent" '[ "$rc" -eq 0 ] && [ -z "$out" ]'
hook; check "a run that works resets the count" '[ "$rc" -eq 2 ] && [ ! -e "$st/autoarm.fails" ]'

# 5. Inert outside the dispatcher's session.
wake 2
out=$(cd "$repo" && DISPATCH_ROLE=aide "$here/autoarm.sh" </dev/null 2>&1); rc=$?
check "the aide's session is not armed" '[ "$rc" -eq 0 ] && [ -z "$out" ]'
out=$(cd "$repo" && DISPATCH_WORKER=w7 "$here/autoarm.sh" </dev/null 2>&1); rc=$?
check "a worker's session is not armed" '[ "$rc" -eq 0 ] && [ -z "$out" ]'

# 6. --checkpoint: the blocking call for a runtime that cannot be woken.
out=$(cd "$repo" && "$here/autoarm.sh" --checkpoint 2>&1); rc=$?
check "a checkpoint returns the wakes" '[ "$rc" -eq 0 ] && says "^wake 2 handback"'
(cd "$repo" && "$here/drain.sh" --ack-through 2 >/dev/null)
out=$(cd "$repo" && DISPATCH_CHECKPOINT_SECS=1 "$here/autoarm.sh" --checkpoint 2>&1); rc=$?
check "a quiet checkpoint says to call again" '[ "$rc" -eq 124 ] && says "^quiet:.*again"'
hook --frob; check "an unknown option is usage" '[ "$rc" -eq 1 ]'

# 7. --hooks: the dispatcher's hooks, which the role guard's own probe accepts.
(cd "$repo" && DISPATCH_ARM_SECS=600 "$here/autoarm.sh" --hooks) > "$tmp/hooks.json"; rc=$?
out=$(cat "$tmp/hooks.json")
check "--hooks prints the Stop and PreToolUse hooks" \
  '[ "$rc" -eq 0 ] &&
   [ "$(jq -r ".hooks | keys | join(\" \")" "$tmp/hooks.json")" = "PreToolUse Stop" ]'
check "autoarm is the asyncRewake hook, with a timeout past the arm time" \
  'r=".hooks.Stop[0].hooks[] | select(.asyncRewake)"
   [ "$(jq -r "$r | .command" "$tmp/hooks.json" | grep -c "autoarm.sh")" -eq 1 ] &&
   [ "$(jq -r "$r | .timeout" "$tmp/hooks.json")" -gt 600 ]'
check "the turn-end guard is a plain Stop hook" \
  'jq -r ".hooks.Stop[0].hooks[] | select(.asyncRewake | not) | .command" "$tmp/hooks.json" |
     grep -q "turnend-guard.sh"'
mkdir -p "$st/guard"; printf 'role=dispatcher\nwrite=.dispatch/\n' > "$st/guard/dispatcher.conf"
out=$(cd "$repo" && DISPATCH_ROLE=dispatcher "$here/role-guard.sh" --probe dispatcher \
  --settings "$tmp/hooks.json" 2>&1); rc=$?
check "the printed role guard denies as the dispatcher" '[ "$rc" -eq 0 ] && says "denied"'

echo "test-autoarm: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
