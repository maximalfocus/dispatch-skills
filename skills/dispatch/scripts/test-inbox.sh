#!/usr/bin/env bash
# test-inbox.sh — hermetic tests for inbox.sh, and for the two wakes watch.sh raises from a
# worker's records (inbox, overdue): a temporary project with a bare "remote", hand-written
# worker records, and a fake tmux that logs what is typed. No network. Exit 0 on all pass.
set -u
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); }
no() { fail=$((fail + 1)); echo "FAIL: $*"; }
check() { if eval "$2"; then ok; else no "$1 (rc=$rc out=$out)"; fi; }

unset DISPATCH_STATE DISPATCH_WORKER DISPATCH_TERM DISPATCH_RING_SECS DISPATCH_REMOTE TMUX \
  DISPATCH_TRUSTED_LOGINS DISPATCH_TRUSTED_AUTHORS DISPATCH_IDLE_SECS DS_LOCK_TRIES HERDR_ENV
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
origin="$tmp/origin.git"; repo="$tmp/project"; fake="$tmp/fake"; mkdir -p "$fake"
git init -q --bare "$origin"; git init -q -b main "$repo"
g() { git -C "$repo" "$@"; }
g remote add origin "$origin"; g commit -q --allow-empty -m base; g push -q origin main
st="$repo/.dispatch/state"; mkdir -p "$st/workers"
cat > "$fake/tmux" <<'EOF'
#!/usr/bin/env bash
case $1 in
  display-message) grep -qxF -- "$4" "$FAKE/panes" ;;
  send-keys) shift; echo "$*" >> "$FAKE/typed" ;;
esac
EOF
cat > "$fake/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in *api\ user*) echo alice ;; *) echo '[]' ;; esac
EOF
chmod +x "$fake/tmux" "$fake/gh"
export FAKE="$fake" DISPATCH_TMUX="$fake/tmux" DISPATCH_GH="$fake/gh" DISPATCH_REPO=o/r \
  DISPATCH_POLL=0
worker() {  # id state [extra meta lines] — a recorded worker in pane %<digits of id>
  local id=$1 s=$2; shift 2
  { echo "issue=${id#w}"; echo "kind=worker"; echo "term=tmux"; echo "handle=%${id#w}"
    echo "branch=issue-${id#w}"; [ $# -eq 0 ] || printf '%s\n' "$@"; } > "$st/workers/$id.meta"
  echo "$s $(date +%s) ${id#w}" > "$st/workers/$id.state"
  grep -qxF "%${id#w}" "$fake/panes" 2>/dev/null || echo "%${id#w}" >> "$fake/panes"
}
inbox() { out=$(cd "$repo" && "$here/inbox.sh" "$@" 2>&1); rc=$?; }
says() { printf '%s' "$out" | grep -q -- "$1"; }
rings() { local n; n=$(grep -c -- "-t %$1 -l" "$fake/typed" 2>/dev/null); echo "${n:-0}"; }
queue() { (cd "$repo" && "$here/drain.sh" 2>/dev/null); }
dir="$st/inbox/w7"

# 1. A message is a numbered file, and an idle worker gets one constant line naming its inbox.
: > "$fake/panes"; worker w7 idle
inbox send w7 update from the base, then hand back
check "send queues message 001" '[ "$rc" -eq 0 ] && says "^queued w7 001\$"'
check "the message is the text, whole" \
  '[ "$(cat "$dir/001.msg")" = "update from the base, then hand back" ]'
check "the terminal got one line and Enter" \
  '[ "$(rings 7)" -eq 1 ] && grep -qx -- "-t %7 Enter" "$fake/typed"'
check "the line names the inbox and how to acknowledge, not the message" \
  'grep -q "dispatch inbox: read each .msg file in $dir in order" "$fake/typed" &&
   grep -q "inbox.sh ack" "$fake/typed" && ! grep -q "update from the base" "$fake/typed"'
inbox list w7; check "list shows the unread message" '[ "$out" = 001.msg ]'
check "no temporary file is left" '[ -z "$(ls -A "$dir" | grep tmp)" ]'

# 2. Re-ring every DISPATCH_RING_SECS, up to 3 times, then one wake.
inbox tick; check "no re-ring before the interval" '[ "$(rings 7)" -eq 1 ]'
export DISPATCH_RING_SECS=0
inbox tick; inbox tick; inbox tick
check "three re-rings follow" '[ "$(rings 7)" -eq 4 ]'
check "no wake while rings remain" '[ -z "$(queue)" ]'
inbox tick
check "then one wake, and no fifth ring" \
  '[ "$(rings 7)" -eq 4 ] && queue | grep -q "inbox worker w7 left message 001 unread"'
inbox tick; inbox tick
check "the wake is raised once" '[ "$(queue | grep -c "^wake ")" -eq 1 ] && [ "$(rings 7)" -eq 4 ]'
(cd "$repo" && "$here/drain.sh" --ack-through 99 >/dev/null)

# 3. The worker acknowledges; numbers are never reused; the next message starts its own rings.
out=$(cd "$tmp" && DISPATCH_STATE="$st" DISPATCH_WORKER=w7 "$here/inbox.sh" ack 1 2>&1); rc=$?
check "the worker acknowledges by number" \
  '[ "$rc" -eq 0 ] && says "acknowledged w7 001" && [ -f "$dir/read/001.msg" ] &&
   [ ! -e "$dir/001.msg" ]'
inbox tick; check "an empty inbox rings nobody" '[ "$(rings 7)" -eq 4 ] && [ -z "$(queue)" ]'
inbox ack 1 --id w7; check "acknowledging twice is an error" '[ "$rc" -eq 1 ] && says "no unread"'
printf 'line one\nline two\n' > "$tmp/m.txt"; inbox send w7 --file "$tmp/m.txt"
check "the next message is 002, never 001 again" \
  'says "queued w7 002" && [ "$(sed -n 2p "$dir/002.msg")" = "line two" ]'
check "a new message rings afresh" '[ "$(rings 7)" -eq 5 ]'

# 4. A busy worker is never rung; it is rung when its turn ends.
worker w8 busy; inbox send w8 stop and hand back
check "a busy worker is not rung" '[ "$rc" -eq 0 ] && [ "$(rings 8)" -eq 0 ]'
inbox tick; inbox tick; check "however long it stays busy" '[ "$(rings 8)" -eq 0 ]'
check "and no wake is raised for it" '! queue | grep -q w8'
worker w8 idle; inbox tick; check "it is rung once it is idle" '[ "$(rings 8)" -eq 1 ]'

# 5. A dead terminal is never rung: one wake instead.
worker w9 idle; sed -i.bak '/^%9$/d' "$fake/panes"; inbox send w9 are you there
check "a dead terminal is not typed into" '[ "$rc" -eq 0 ] && [ "$(rings 9)" -eq 0 ]'
check "the dispatcher is woken at once" 'queue | grep -q "worker w9.s terminal is gone"'
inbox tick; check "once" '[ "$(queue | grep -c "w9")" -eq 1 ]'
(cd "$repo" && "$here/drain.sh" --ack-through 99 >/dev/null)

# 6. Errors.
inbox send w99 hello
check "an unknown worker is an error" '[ "$rc" -eq 1 ] && says "no worker w99"'
inbox send w7; check "an empty message is an error" '[ "$rc" -eq 1 ]'
inbox send ../x hi; check "an id with a path is usage" '[ "$rc" -eq 1 ]'
inbox ack x --id w7; check "a non-numeric ack is usage" '[ "$rc" -eq 1 ]'
inbox frob; check "an unknown command is usage" '[ "$rc" -eq 1 ]'

# 7. watch.sh rings on every poll, and wakes the dispatcher for an unread message.
watch() { out=$(cd "$repo" && "$here/watch.sh" --once 2>&1); rc=$?; }
watch >/dev/null  # the first run only sets the comment cursor
worker w8 idle; before=$(rings 8); watch
check "a poll re-rings a due worker" '[ "$(rings 8)" -gt "$before" ]'
watch; watch; watch
check "and wakes once its rings are spent" '[ "$rc" -eq 0 ] && says "inbox worker w8 left message"'
(cd "$repo" && "$here/drain.sh" --ack-through 99 >/dev/null)
rm -rf "$st/inbox"

# 8. Overdue: a busy worker past its TIMEBOX with no new push, once per worker and TIMEBOX.
old=$(( $(date +%s) - 1000 ))
worker w5 busy "timebox=600" "started=$old"
watch; check "a busy worker past its TIMEBOX wakes" \
  '[ "$rc" -eq 0 ] && says "overdue worker w5 (issue #5) is past its TIMEBOX"'
(cd "$repo" && "$here/drain.sh" --ack-through 99 >/dev/null)
watch; check "once per TIMEBOX" '[ "$rc" -eq 124 ]'
worker w6 busy "timebox=600" "started=$(date +%s)"
watch; check "a worker inside its TIMEBOX is quiet" '[ "$rc" -eq 124 ]'
worker w4 idle "timebox=600" "started=$old"; echo "idle $(date +%s) 4" > "$st/workers/w4.state"
watch; check "an idle worker is not overdue" '! says overdue'
worker w3 busy "timebox=600" "started=$old"; g push -q origin main:refs/heads/issue-3
watch; check "a push before the TIMEBOX ran out restarts it" \
  '! says "worker w3" && grep -q "^progress=" "$st/workers/w3.meta"'
sed -i.bak "s/^progress=.*/progress=$old/" "$st/workers/w3.meta"
watch; check "no new push in the next TIMEBOX wakes" 'says "overdue worker w3"'
(cd "$repo" && "$here/drain.sh" --ack-through 99 >/dev/null)
worker w2 busy "timebox=600" "started=$old"; g remote set-url origin "$tmp/gone.git"
watch; check "an unreachable remote proves nothing and wakes nobody" '! says "worker w2"'

echo "test-inbox: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
