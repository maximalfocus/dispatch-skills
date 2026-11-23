#!/usr/bin/env bash
# test-board.sh — hermetic tests for board.sh: a temporary project, hand-written worker records,
# and a fake gh serving fixture JSON. No network. Exit 0 when every case passes.
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
repo="$tmp/project"; fake="$tmp/fake"; mkdir -p "$fake"
git init -q -b main "$repo"; git -C "$repo" commit -q --allow-empty -m base
st="$repo/.dispatch/state"; mkdir -p "$st/workers"
cat > "$fake/gh" <<'EOF'
#!/usr/bin/env bash
[ ! -f "$FAKE/down" ] || exit 1
case "$*" in
  issue\ list*) cat "$FAKE/issues.json" ;;
  pr\ list*) cat "$FAKE/prs.json" ;;
  *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$fake/gh"
export FAKE="$fake" DISPATCH_GH="$fake/gh" DISPATCH_REPO=o/r
echo '[]' > "$fake/issues.json"; echo '[]' > "$fake/prs.json"
sleep 300 & live=$!
trap 'kill "$live" 2>/dev/null; wait 2>/dev/null; rm -rf "$tmp"' EXIT
board() { out=$(cd "$repo" && "$here/board.sh" "$@" 2>&1); rc=$?; }
says() { printf '%s\n' "$out" | grep -q -- "$1"; }
issue() { jq -n --argjson n "$1" --arg t "$2" --arg s "${3:-OPEN}" --arg l "${4:-}" \
  '{number: $n, title: $t, state: $s, labels: (if $l == "" then [] else [{name: $l}] end)}'; }
pr() {  # number title branch [state] [draft]
  jq -n --argjson n "$1" --arg t "$2" --arg b "$3" --arg s "${4:-OPEN}" --argjson d "${5:-false}" \
    '{number: $n, title: $t, headRefName: $b, state: $s, isDraft: $d}'
}
worker() {  # id issue state [kind] — records as start.sh leaves them, and a line in the start log
  printf 'issue=%s\nkind=%s\nbranch=issue-%s\n' "$2" "${4:-worker}" "$2" > "$st/workers/$1.meta"
  echo "$3 $(( $(date +%s) - 900 )) $2" > "$st/workers/$1.state"
  echo "$(date +%s) $1 $2 ${4:-worker} issue-$2" >> "$st/starts"
}
gone() { rm -f "$st/workers/$1".*; }  # as teardown.sh leaves a worker

# 1. An empty project still renders, to the screen and to the file, and keeps nothing else.
board; check "an empty project renders" \
  '[ "$rc" -eq 0 ] && says "^# Board: o/r" && says "^## Asks open (0)" &&
   says "^## Issues open (0)"'
check "the watcher line says not armed" 'says "^watcher: NOT ARMED   wakes waiting: 0"'
check "the file is the same text" '[ "$out" = "$(cat "$repo/.dispatch/board.md")" ]'
check "it keeps nothing of its own" '[ "$(ls "$st")" = workers ]'

# 2. Issues, asks, PRs.
{ issue 1 "Add login"; issue 2 "Which database?" OPEN ask; issue 3 "Old work" CLOSED
  issue 4 "$(printf 'Odd\ttitle\001 here')"; } | jq -s . > "$fake/issues.json"
{ pr 10 "Add login" issue-1; pr 11 "Draft thing" issue-4 OPEN true; pr 9 "Old" issue-3 MERGED
} | jq -s . > "$fake/prs.json"
board
check "an ask is listed under asks only" \
  'says "^## Asks open (1)" && [ "$(printf "%s\n" "$out" | grep -c "Which database")" -eq 1 ]'
check "open issues exclude asks and closed ones" 'says "^## Issues open (2)" && ! says "Old work"'
check "open PRs show their branch and draft state" \
  'says "^## PRs open (2)" && says "^#10 Add login (issue-1)\$" &&
   says "^#11 Draft thing (issue-4) draft\$"'
check "a title's control characters are cleaned" 'says "^#4 Odd title here\$"'

# 3. Workers in flight, from their own records.
worker w1 1 busy; worker w4 4 idle
board
check "workers show state, age, branch, and PR" \
  'says "^## Workers in flight (2)" && says "^w1 #1 worker busy 15m issue-1 PR #10\$"'
mkdir -p "$st/watch.lock"; echo "$live" > "$st/watch.lock/pid"; touch "$st/watch.beat"
printf '1\t1\thandback\tk\tx\n' > "$st/wake-queue"
board; check "an armed watcher and waiting wakes show" \
  'says "^watcher: armed (pid $live)   wakes waiting: 1\$"'

# 4. Every worker started since the last stage report has an end, or a flag.
worker w3 3 idle; gone w3                       # its PR #9 is merged
worker w5 5 idle; gone w5                       # issue 5 closed, no PR: absorbed
worker w6 6 busy; gone w6                       # nothing: unaccounted
worker w7 7 ended                               # session over, not landed
worker w8 8 idle; worker w8b 8 busy             # relaunched under another id
worker s9 9 idle scout; gone s9                 # a scout that reported and was torn down
{ issue 1 "Add login"; issue 5 "Folded into 1" CLOSED; issue 6 "Lost"; issue 7 "Stuck"
  issue 8 "Retry"; } | jq -s . > "$fake/issues.json"
board
check "running" 'says "^w1 #1 running\$"'
check "landed, by its merged PR" 'says "^w3 #3 landed (PR #9)\$"'
check "absorbed, by its closed issue" 'says "^w5 #5 absorbed"'
check "replaced, by a later start for the issue" \
  'says "^w8 #8 replaced by a later start\$" && says "^w8b #8 running\$"'
check "a scout that was torn down has ended" 'says "^s9 #9 ended\$"'
check "a worker with no record and no end is flagged" 'says "^! w6 #6 UNACCOUNTED"'
check "a session that is over and not landed is flagged" \
  'says "^! w7 #7 session ended, not landed"'
check "the section counts every start" 'says "^## Started since the last stage report (9)"'
board --stage-reported; check "a stage report can be marked" '[ "$rc" -eq 0 ]'
sleep 1; worker w12 12 busy; board
check "accounting restarts at the stage report" \
  'says "^## Started since the last stage report (1)" && says "^w12 #12 running\$" &&
   ! says UNACCOUNTED'

# 5. Never more than 80 lines, and never appended.
for i in $(seq 100 260); do issue "$i" "Issue number $i"; done | jq -s . > "$fake/issues.json"
for i in $(seq 300 340); do pr "$i" "PR number $i" "b$i"; done | jq -s . > "$fake/prs.json"
for i in $(seq 20 45); do worker "x$i" "$i" busy; done
board; lines=$(printf '%s\n' "$out" | wc -l)
check "a large project stays within 80 lines" '[ "$lines" -le 80 ] && [ "$lines" -gt 60 ]'
check "what is cut is counted" 'says "^## Issues open (161)" && says "^\.\.\. and 141 more\$"'
board; check "the file is overwritten, not appended" \
  '[ "$(wc -l < "$repo/.dispatch/board.md")" -eq "$lines" ]'
issue 1 "$(printf 'x%.0s' $(seq 1 300))" | jq -s . > "$fake/issues.json"; board
widest=$(printf '%s\n' "$out" | awk '{ print length }' | sort -n | tail -n 1)
check "a long title is cut" '[ "$widest" -le 110 ]'

# 6. GitHub unreachable: the local facts still render, and the board says what is missing.
touch "$fake/down"; board
check "an unreadable GitHub exits 1 and says so" \
  '[ "$rc" -eq 1 ] && says "^! GitHub could not be read" && says "^## Workers in flight (32)"'
rm "$fake/down"; board frob; check "an unknown option is usage" '[ "$rc" -eq 1 ]'

echo "test-board: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
