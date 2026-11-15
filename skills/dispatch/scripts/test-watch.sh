#!/usr/bin/env bash
# test-watch.sh — hermetic tests for watch.sh and drain.sh: a temporary git repo and a fake gh
# that serves fixture JSON. No network. Exit 0 when every case passes.
set -u
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); }
no() { fail=$((fail + 1)); echo "FAIL: $*"; }
check() { if eval "$2"; then ok; else no "$1"; fi; }

repo="$tmp/project"; fake="$tmp/fake"; mkdir -p "$repo" "$fake"
git -C "$repo" init -q
cat > "$fake/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *api\ user*) echo alice ;;
  *issues/comments*) cat "$FAKE/comments.json" ;;
  *pulls*) cat "$FAKE/pulls.json" ;;
  *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$fake/gh"
echo '[]' > "$fake/comments.json"; echo '[]' > "$fake/pulls.json"
# Hermetic: the operator's own dispatch environment must not decide the outcome.
unset DISPATCH_STATE DISPATCH_IDLE_SECS DISPATCH_TRUSTED_LOGINS DISPATCH_TRUSTED_AUTHORS \
  DISPATCH_REPO DISPATCH_GH DS_LOCK_TRIES
export FAKE="$fake" DISPATCH_GH="$fake/gh" DISPATCH_REPO=o/r DISPATCH_POLL=0
st="$repo/.dispatch/state"
watch() { (cd "$repo" && "$here/watch.sh" --once "$@"); }
drain() { (cd "$repo" && "$here/drain.sh" "$@"); }
comment() {  # id body [author_association] [user.login]
  jq -n --argjson id "$1" --arg b "$2" --arg a "${3:-OWNER}" --arg l "${4:-alice}" \
    '{id: $id, body: $b, html_url: "https://x/c/\($id)", author_association: $a,
      user: {login: $l}, updated_at: "2026-11-14T00:00:0\($id % 10)Z"}'
}
comments() { jq -s . > "$fake/comments.json"; }

# 1. First run starts the cursor at now, replays nothing, and keeps state out of git.
comment 1 "HANDBACK issue=#9 pr=#10 head=aaa111 status=done" | comments
watch >/dev/null; rc=$?
check "first run is quiet" '[ "$rc" -eq 124 ]'
comment 11 "just a note, no hand-back" | comments
watch >/dev/null 2>"$tmp/err1"; rc=$?
check "a comment with no event line is quiet" '[ "$rc" -eq 124 ]'
check "a quiet tick writes nothing to stderr" '[ ! -s "$tmp/err1" ]'
out=$(drain --ack-through 5 2>"$tmp/errd"); rc=$?
check "an ack before any queue file is clean" \
  '[ "$rc" -eq 0 ] && [ ! -s "$tmp/errd" ] && printf "%s" "$out" | grep -q "0 left"'
check "state excluded from git" 'grep -qxF /.dispatch/ "$repo/.git/info/exclude"'
check "status clean" '[ -z "$(git -C "$repo" status --porcelain)" ]'

# 2. A hand-back wakes once; unacknowledged wakes repeat; acknowledged ones never return.
{ comment 2 "note
HANDBACK issue=#9 pr=#10 head=aaa111 status=done
gate=npm test exit=0"; comment 3 "ACCEPT-REQ issue=#9 head=aaa111 env=staging tier=1"; } | comments
out=$(watch); rc=$?
has() { printf '%s' "$out" | grep -q "$1"; }
check "hand-back wakes" '[ "$rc" -eq 0 ] && has "^wake 1 handback HANDBACK issue=#9"'
check "ACCEPT-REQ does not wake" '! printf "%s" "$out" | grep -q ACCEPT-REQ'
check "ack command printed" 'printf "%s" "$out" | grep -q -- "--ack-through 1"'
out=$(watch); check "unacknowledged wake repeats" 'printf "%s" "$out" | grep -q "^wake 1 handback"'
drain --ack-through 1 >/dev/null
watch >/dev/null; rc=$?
check "acknowledged wake does not return" '[ "$rc" -eq 124 ]'
drain >/dev/null; rc=$?; check "drain on empty queue exits 124" '[ "$rc" -eq 124 ]'

# 3. A verdict wakes; --ack-through N removes only seq <= N.
{ comment 4 "ACCEPT issue=#9 head=aaa111 verdict=FAIL evidence=x";
  comment 5 "ACCEPT issue=#9 head=aaa111 verdict=PASS evidence=y"; } | comments
out=$(watch); check "verdict wakes" 'printf "%s" "$out" | grep -q "verdict ACCEPT issue=#9"'
check "both verdicts are queued" 'printf "%s" "$out" | grep -c "^wake " | grep -qx 2'
first=$(printf '%s\n' "$out" | awk '/^wake [0-9]+ /{ print $2; exit }')
drain --ack-through "$first" >/dev/null
out=$(watch); check "the ack removed only seq <= N" \
  'printf "%s" "$out" | grep -q "^wake $((first + 1)) verdict"'
drain --ack-through 999 >/dev/null

# 4. A handed-back PR wakes only when its live head moved.
echo '[{"number":10,"head":{"sha":"aaa111ffff"}},{"number":11,"head":{"sha":"bbb"}}]' \
  > "$fake/pulls.json"
watch >/dev/null; rc=$?; check "same head is quiet" '[ "$rc" -eq 124 ]'
echo '[{"number":10,"head":{"sha":"ccc222"}}]' > "$fake/pulls.json"
out=$(watch); check "moved head wakes" 'has "head PR #10 head moved to ccc222"'
drain --ack-through 99 >/dev/null
watch >/dev/null; rc=$?; check "moved head wakes once" '[ "$rc" -eq 124 ]'

# 5. Idle workers wake only without a recent hand-back.
old=$(( $(date +%s) - 1000 ))
echo "idle $old 12" > "$st/workers/w12.state"
echo "busy $old 13" > "$st/workers/w13.state"
out=$(watch); check "idle worker without hand-back wakes" 'has "idle worker w12"'
check "busy worker is quiet" '! printf "%s" "$out" | grep -q w13'
drain --ack-through 99 >/dev/null
echo "idle $(( $(date +%s) - 400 )) 9" > "$st/workers/w9.state"
watch >/dev/null; rc=$?; check "idle right after its hand-back is quiet" '[ "$rc" -eq 124 ]'

# 6. One watcher per project; a dead holder's lock is reclaimed.
mkdir -p "$st/watch.lock"; echo $$ > "$st/watch.lock/pid"
watch >/dev/null 2>&1; rc=$?; check "second watcher refused" '[ "$rc" -eq 3 ]'
echo 999999 > "$st/watch.lock/pid"
watch >/dev/null 2>&1; rc=$?; check "dead holder reclaimed" '[ "$rc" -eq 124 ]'
check "lock released on exit" '[ ! -d "$st/watch.lock" ]'
check "beacon written" '[ -f "$st/watch.beat" ]'

# 7. GitHub failures are reported, not swallowed, and do not crash the watcher.
echo 'not json' > "$fake/comments.json"
watch >/dev/null 2>"$tmp/err"; rc=$?
check "bad response is survivable" '[ "$rc" -eq 124 ]'
check "bad response is reported" 'grep -q "GitHub poll failed (1 in a row)" "$tmp/err"'

# 8. A hand-back without head= must not shift its row; a bad worker state file must not kill us.
echo '[]' > "$fake/comments.json"; echo '[]' > "$fake/pulls.json"
comment 50 "HANDBACK issue=#20 pr=#20 status=done" | comments
out=$(watch); rc=$?
check "hand-back without a head still wakes" '[ "$rc" -eq 0 ] && has handback'
drain --ack-through 99 >/dev/null
# An odd response without html_url must not shift the trust flag out of its column.
jq -n '[{id: 51, body: "HANDBACK issue=#21 pr=#21 head=f00d status=done",
  author_association: "OWNER", user: {login: "alice"},
  updated_at: "2026-11-14T00:00:09Z"}]' > "$fake/comments.json"
out=$(watch 2>"$tmp/err8u"); rc=$?
check "a comment with no html_url still wakes" '[ "$rc" -eq 0 ] && has f00d'
check "and is not called untrusted" '! grep -q "comment 51" "$tmp/err8u"'
drain --ack-through 999 >/dev/null
echo '[{"number":20,"head":{"sha":"ffff"}}]' > "$fake/pulls.json"
echo "idle $(( $(date +%s) - 400 )) 20" > "$st/workers/w20.state"
watch >/dev/null 2>"$tmp/err8"; rc=$?
check "no head recorded, idle suppressed" '[ "$rc" -eq 124 ]'
echo "idle notanumber 20" > "$st/workers/w20.state"
watch >/dev/null 2>"$tmp/err8"; rc=$?
check "bad worker state file survives" '[ "$rc" -eq 124 ] && grep -q "no idle epoch" "$tmp/err8"'
printf 'idle' > "$st/workers/w21.state"
watch >/dev/null 2>"$tmp/err8b"; rc=$?
check "a half-written 'idle' is noted" '[ "$rc" -eq 124 ] && grep -q "no idle epoch" "$tmp/err8b"'
printf 'idle 0999 8\n' > "$st/workers/w23.state"
out=$(watch 2>"$tmp/err8d"); rc=$?
check "a zero-padded epoch does not kill the run" '[ "$rc" -eq 0 ] && has w23'
drain --ack-through 999 >/dev/null
rm -f "$st/workers/w23.state"
: > "$st/workers/w22.state"
watch >/dev/null 2>"$tmp/err8c"; rc=$?
check "an empty state file is noted" '[ "$rc" -eq 124 ] && grep -q "empty worker" "$tmp/err8c"'
rm -f "$st/workers/w20.state" "$st/workers/w21.state" "$st/workers/w22.state"
# 9. Trust is identity first, association second; an outsider's line is noted once.
echo '[]' > "$fake/pulls.json"
# (a) association: a collaborator who is not the gh login still wakes.
comment 60 "ACCEPT issue=#9 head=aaaa verdict=PASS evidence=x" COLLABORATOR carol | comments
out=$(watch); check "a COLLABORATOR wakes" 'has "verdict ACCEPT issue=#9"'
drain --ack-through 999 >/dev/null
# (b) identity: the login gh posts as is trusted even as a bare org member.
comment 61 "HANDBACK issue=#9 pr=#30 head=f00d status=done" MEMBER alice | comments
out=$(watch); check "the gh login wakes as a MEMBER" 'has f00d'
drain --ack-through 999 >/dev/null
# (c) another member's line is data: no wake, no row, one note.
comment 62 "HANDBACK issue=#9 pr=#31 head=beef status=done" MEMBER mallory | comments
out=$(watch 2>"$tmp/err9"); rc=$?
check "another MEMBER's hand-back never wakes" '[ "$rc" -eq 124 ] && ! has beef'
check "no hand-back was recorded" '! grep -q beef "$st/handbacks"'
check "the outsider is noted once" 'grep -q "comment 62" "$tmp/err9"'
out=$(watch 2>"$tmp/err9b"); check "the note does not repeat" '! grep -q "comment 62" "$tmp/err9b"'
# (d) DISPATCH_TRUSTED_LOGINS replaces the default identity, case-insensitively.
out=$( cd "$repo" && DISPATCH_TRUSTED_LOGINS="Mallory" "$here/watch.sh" --once 2>/dev/null )
check "a configured login is trusted" 'has beef'
drain --ack-through 999 >/dev/null
comment 63 "HANDBACK issue=#9 pr=#32 head=cafe status=done" MEMBER alice | comments
out=$( cd "$repo" && DISPATCH_TRUSTED_LOGINS="mallory" "$here/watch.sh" --once 2>/dev/null ); rc=$?
check "the replaced list no longer trusts the gh login" '[ "$rc" -eq 124 ]'
# (e) no login and no override: refuse to run rather than go deaf.
( cd "$repo" && DISPATCH_GH=/bin/false "$here/watch.sh" --once ) >/dev/null 2>"$tmp/err9e"; rc=$?
check "an unknown login exits 1" '[ "$rc" -eq 1 ] && grep -q DISPATCH_TRUSTED_LOGINS "$tmp/err9e"'

# 10. Reclaiming a dead holder runs under the steal mutex, so a second starter cannot steal.
rm -rf "$st/watch.lock" "$st/watch.mutex"; mkdir -p "$st/watch.lock" "$st/watch.mutex"
echo 999999 > "$st/watch.lock/pid"; echo $$ > "$st/watch.mutex/pid"
echo '[]' > "$fake/comments.json"
( cd "$repo" && DS_LOCK_TRIES=3 "$here/watch.sh" --once ) >/dev/null 2>&1; rc=$?
check "blocked stealer exits 1" '[ "$rc" -eq 1 ]'
check "it left the stale lock alone" '[ "$(cat "$st/watch.lock/pid")" = 999999 ]'
rm -rf "$st/watch.lock" "$st/watch.mutex"
watch >/dev/null 2>&1; rc=$?
check "steal mutex released after a run" '[ "$rc" -eq 124 ] && [ ! -d "$st/watch.mutex" ]'

# 11. Failures are counted across runs, so a --once checkpoint still reports a long outage.
echo 19 > "$st/gh-fails"; echo 'not json' > "$fake/comments.json"
out=$(watch 2>/dev/null); rc=$?
check "20th failure in a row wakes" '[ "$rc" -eq 0 ] && has "error GitHub unreachable"'
drain --ack-through 999 >/dev/null; echo '[]' > "$fake/comments.json"
watch >/dev/null 2>&1
check "a success resets the counter" '[ "$(cat "$st/gh-fails")" = 0 ]'

echo "test-watch: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
