#!/usr/bin/env bash
# test-teardown.sh — hermetic tests for teardown.sh: a bare "remote", a project clone with linked
# worktrees, and a fake gh that reports a PR's state. No network. Exit 0 when every case passes.
set -u
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); }
no() { fail=$((fail + 1)); echo "FAIL: $*"; }
check() { if eval "$2"; then ok; else no "$1 (rc=$rc out=$out)"; fi; }

unset DISPATCH_STATE DISPATCH_REPO DISPATCH_GH DISPATCH_REMOTE
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
origin="$tmp/origin.git"; repo="$tmp/project"; fake="$tmp/fake"; mkdir -p "$fake"
git init -q --bare "$origin"
git init -q -b main "$repo"
g() { git -C "$repo" "$@"; }
g remote add origin "$origin"
echo a > "$repo/a.txt"; g add -A; g commit -q -m base; g push -q origin main
cat > "$fake/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  pr\ view*) printf '{"state":"%s"}\n' "$(cat "$FAKE/pr-state")" ;;
  *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$fake/gh"
export FAKE="$fake" DISPATCH_GH="$fake/gh" DISPATCH_REPO=o/r
echo OPEN > "$fake/pr-state"

worktree() {  # name — a linked worktree on its own branch with one unpushed commit
  wt="$tmp/$1"; g worktree add -q -b "$1" "$wt" main 2>/dev/null
  echo "work $1" > "$wt/$1.txt"; git -C "$wt" add -A; git -C "$wt" commit -q -m "work $1"
}
teardown() { out=$(cd "$repo" && "$here/teardown.sh" "$@" 2>&1); rc=$?; }
says() { printf '%s' "$out" | grep -q -- "$1"; }
has_branch() { g rev-parse -q --verify "refs/heads/$1" >/dev/null; }

# 1. Unlanded work is never removed; once it is on the remote, the worktree and branch go.
worktree w1; teardown "$wt"
check "an unpushed commit refuses" '[ "$rc" -eq 2 ] && says "unlanded work" && [ -d "$wt" ]'
git -C "$wt" push -q origin w1
echo scratch > "$wt/untracked.txt"; teardown "$wt"
check "an untracked file refuses" '[ "$rc" -eq 2 ] && says "refused:" && [ -d "$wt" ]'
rm "$wt/untracked.txt"; echo edit >> "$wt/a.txt"; teardown "$wt"
check "an uncommitted edit refuses" '[ "$rc" -eq 2 ] && [ -d "$wt" ]'
git -C "$wt" checkout -q a.txt; teardown "$wt"
check "a pushed, clean worktree is removed" '[ "$rc" -eq 0 ] && [ ! -d "$wt" ]'
check "the reason names the fact" 'says "HEAD is on a origin branch"'
check "its local branch is deleted" '! has_branch w1'

# 2. A branch deleted on the remote after a squash merge is safe only through its merged PR.
worktree w2; git -C "$wt" push -q origin "w2:refs/pull/7/head"
teardown "$wt"; check "a PR head alone proves nothing" '[ "$rc" -eq 2 ] && [ -d "$wt" ]'
teardown "$wt" --pr 7; check "an open PR refuses" '[ "$rc" -eq 2 ] && [ -d "$wt" ]'
echo MERGED > "$fake/pr-state"
echo late > "$wt/late.txt"; git -C "$wt" add -A; git -C "$wt" commit -q -m "after the merge"
teardown "$wt" --pr 7
check "a commit made after the merged head refuses" '[ "$rc" -eq 2 ] && [ -d "$wt" ]'
git -C "$wt" reset -q --hard HEAD~1; teardown "$wt" --pr "#7"
check "HEAD inside the merged PR head is removed" \
  '[ "$rc" -eq 0 ] && [ ! -d "$wt" ] && says "merged PR #7" && ! has_branch w2'
check "no temporary ref is left" '[ -z "$(g for-each-ref refs/dispatch)" ]'

# 3. Content identical to the base is safe even when the commits differ.
worktree w3
cp "$wt/w3.txt" "$repo/w3.txt"; g add -A; g commit -q -m "squashed w3"; g push -q origin main
teardown "$wt"; check "without --base it refuses" '[ "$rc" -eq 2 ] && [ -d "$wt" ]'
teardown "$wt" --base main
check "identical content to the base is removed" \
  '[ "$rc" -eq 0 ] && [ ! -d "$wt" ] && says "identical in content"'
worktree w4; teardown "$wt" --base main
check "different content from the base refuses" '[ "$rc" -eq 2 ] && [ -d "$wt" ]'

# 4. A scout goes only with its report, and keeps a branch whose work is nowhere else.
teardown "$wt" --scout
check "a scout with no report refuses" '[ "$rc" -eq 2 ] && says "missing or empty" && [ -d "$wt" ]'
: > "$tmp/report.md"; teardown "$wt" --scout --report "$tmp/report.md"
check "an empty report refuses" '[ "$rc" -eq 2 ] && [ -d "$wt" ]'
echo findings > "$wt/report.md"; git -C "$wt" add -A; git -C "$wt" commit -q -m report
teardown "$wt" --scout --report "$wt/report.md"
check "a report inside the worktree refuses" '[ "$rc" -eq 2 ] && says "inside" && [ -d "$wt" ]'
echo findings > "$tmp/report.md"
st="$repo/.dispatch/state"; mkdir -p "$st/workers"
echo "idle 1 4" > "$st/workers/w4.state"; echo x > "$st/workers/w4.meta"
echo "busy 1 5" > "$st/workers/w44.state"
teardown "$wt" --scout --report "$tmp/report.md" --worker w4
check "a scout with its report is removed" '[ "$rc" -eq 0 ] && [ ! -d "$wt" ]'
check "its unpushed branch is kept" 'has_branch w4 && says "kept branch w4"'
check "--worker clears that worker's state files" \
  '[ ! -e "$st/workers/w4.state" ] && [ ! -e "$st/workers/w4.meta" ]'
check "and no other worker's" '[ -f "$st/workers/w44.state" ]'

# 5. Only a linked worktree of this project is ever a target.
teardown "$repo"; check "the main checkout is an error" '[ "$rc" -eq 1 ] && [ -d "$repo/.git" ]'
git init -q "$tmp/other"; teardown "$tmp/other"
check "another repository is an error" '[ "$rc" -eq 1 ] && [ -d "$tmp/other/.git" ]'
teardown "$tmp/nowhere"; check "a missing path is an error" '[ "$rc" -eq 1 ]'
worktree w5; git -C "$wt" push -q origin w5; mkdir "$wt/sub"
teardown "$wt/sub"; check "a subdirectory is an error" '[ "$rc" -eq 1 ] && [ -d "$wt" ]'
rmdir "$wt/sub"
teardown "$wt" --worker ../x; check "a worker id with a path is usage" '[ "$rc" -eq 1 ]'

# 6. With the remote unreachable nothing proves safety: an error, and the worktree stays.
g remote set-url origin "$tmp/gone.git"; teardown "$wt"
check "an unreachable remote is an error" '[ "$rc" -eq 1 ] && says "cannot fetch" && [ -d "$wt" ]'

echo "test-teardown: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
