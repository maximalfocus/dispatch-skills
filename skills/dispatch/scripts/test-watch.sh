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
  *issues/comments*) cat "$FAKE/comments.json" ;;
  *pulls*) cat "$FAKE/pulls.json" ;;
  *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$fake/gh"
echo '[]' > "$fake/comments.json"; echo '[]' > "$fake/pulls.json"
export FAKE="$fake" DISPATCH_GH="$fake/gh" DISPATCH_REPO=o/r DISPATCH_POLL=0
st="$repo/.dispatch/state"
watch() { (cd "$repo" && "$here/watch.sh" --once "$@"); }
drain() { (cd "$repo" && "$here/drain.sh" "$@"); }
comment() {  # id body
  jq -n --argjson id "$1" --arg b "$2" \
    '{id: $id, body: $b, html_url: "https://x/c/\($id)",
      updated_at: "2026-11-14T00:00:0\($id % 10)Z"}'
}
comments() { jq -s . > "$fake/comments.json"; }

# 1. First run starts the cursor at now, replays nothing, and keeps state out of git.
comment 1 "HANDBACK issue=#9 pr=#10 head=aaa111 status=done" | comments
watch >/dev/null; rc=$?
check "first run is quiet" '[ "$rc" -eq 124 ]'
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

# 3. A verdict wakes.
comment 4 "ACCEPT issue=#9 head=aaa111 verdict=FAIL evidence=x" | comments
out=$(watch); check "verdict wakes" 'printf "%s" "$out" | grep -q "verdict ACCEPT issue=#9"'
drain --ack-through 99 >/dev/null

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
echo '[{"number":20,"head":{"sha":"ffff"}}]' > "$fake/pulls.json"
echo "idle $(( $(date +%s) - 400 )) 20" > "$st/workers/w20.state"
watch >/dev/null 2>"$tmp/err8"; rc=$?
check "no head recorded, idle suppressed" '[ "$rc" -eq 124 ]'
echo "idle notanumber 20" > "$st/workers/w20.state"
watch >/dev/null 2>"$tmp/err8"; rc=$?
check "bad worker state file survives" '[ "$rc" -eq 124 ] && grep -q "no idle epoch" "$tmp/err8"'
rm -f "$st/workers/w20.state"

echo "test-watch: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
