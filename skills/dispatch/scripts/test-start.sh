#!/usr/bin/env bash
# test-start.sh — hermetic tests for start.sh and runtime.sh: a bare "remote", a project clone,
# a fake tmux and herdr that run the command they are given, and a fake agent that fires its own
# hooks as the real one would. HOME is temporary. No network. Exit 0 when every case passes.
set -u
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); }
no() { fail=$((fail + 1)); echo "FAIL: $*"; }
check() { if eval "$2"; then ok; else no "$1 (rc=$rc out=$out)"; fi; }

unset DISPATCH_STATE DISPATCH_WORKER DISPATCH_ROLE DISPATCH_GUARD_CONFIG DISPATCH_AGENT TMUX \
  DISPATCH_REMOTE HERDR_ENV CODEX_HOME CLAUDE_PROJECT_DIR DS_LOCK_TRIES
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export HOME="$tmp/home"; mkdir -p "$HOME"
origin="$tmp/origin.git"; repo="$tmp/project"; fake="$tmp/fake"; mkdir -p "$fake"
git init -q --bare "$origin"; git init -q -b main "$repo"
g() { git -C "$repo" "$@"; }
g remote add origin "$origin"
echo a > "$repo/a.txt"; g add -A; g commit -q -m base; g push -q origin main
st="$repo/.dispatch/state"

cat > "$fake/tmux" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE/term.calls"
case $1 in
  new-window|new-session)
    while [ $# -gt 1 ]; do [ "$1" != -c ] || dir=$2; shift; done
    n=$(( $(wc -l < "$FAKE/panes") + 1 )); echo "%$n" >> "$FAKE/panes"
    (cd "$dir" && sh -c "$1" > "$FAKE/pane.log" 2>&1 &)
    echo "%$n" ;;
  display-message) grep -qxF -- "$4" "$FAKE/panes" ;;
esac
EOF
cat > "$fake/herdr" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE/term.calls"
case "$1 $2" in
  "pane split") echo "w1:p9" >> "$FAKE/panes"; echo '{"result":{"pane":{"pane_id":"w1:p9"}}}' ;;
  "pane run") dir=$(sed -n 's/.*--cwd \([^ ]*\) .*/\1/p' "$FAKE/term.calls" | tail -n 1)
    (cd "$dir" && sh -c "$4" > "$FAKE/pane.log" 2>&1 &) ;;
  "pane get") grep -qxF -- "$3" "$FAKE/panes" ;;
esac
EOF
cat > "$fake/agent" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE/agent.args"; env | grep '^DISPATCH_' > "$FAKE/agent.env"
[ "$(cat "$FAKE/agent-mode")" = ok ] || exit 0   # anything else: stuck on a screen, no hook fires
hooks=${CODEX_HOME:-none}/hooks.json; [ "$1" != --settings ] || hooks=$2
jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$hooks" | sh
EOF
chmod +x "$fake/tmux" "$fake/herdr" "$fake/agent"
export FAKE="$fake" DISPATCH_TMUX="$fake/tmux" DISPATCH_HERDR="$fake/herdr" \
  DISPATCH_AGENT_BIN="$fake/agent" DISPATCH_TERM=tmux DISPATCH_START_WAIT=5
reset() {
  : > "$fake/panes"; rm -f "$fake/term.calls" "$fake/agent.args"; echo ok > "$fake/agent-mode"
  rm -rf "$st/workers" "$st/guard"
}
brief() {  # issue [sed edit] — write a Brief for that issue and name it in $b
  b="$tmp/brief-$1.txt"
  sed "${2:-}" > "$b" <<EOF
ISSUE #$1 Add the thing   REPO o/r   BASE main   WORKTREE $tmp/wt$1
WHY      users need the thing
GOAL     the thing works   ACCEPT criteria in the issue   TIER 2
GATE     npm test
LIMITS   write=src/ tests/ deny=src/gen; no production data; no grants
TIMEBOX  90m; on expiry, hand back status=blocked
HANDBACK post the Hand-back as a PR comment, then stop
EOF
}
start() { out=$(cd "$repo" && "$here/start.sh" "$@" 2>&1); rc=$?; }
says() { printf '%s' "$out" | grep -q -- "$1"; }
meta() { sed -n "s/^$1=//p" "$st/workers/$2.meta" | head -n 1; }
opened() {  # how many terminals were opened
  local n; n=$(grep -c '^new-\|^pane split' "$fake/term.calls" 2>/dev/null); echo "${n:-0}"
}

# 1. A good Brief starts a confirmed worker in its own worktree.
reset; brief 12; start --brief "$b"
check "a worker starts" '[ "$rc" -eq 0 ] && says "^started w12 issue=#12 agent=claude tmux=%1"'
check "its worktree is on issue-12 from the remote base" \
  '[ "$(git -C "$tmp/wt12" symbolic-ref --short HEAD)" = issue-12 ] &&
   [ "$(git -C "$tmp/wt12" rev-parse HEAD)" = "$(g rev-parse origin/main)" ]'
check "its own hook wrote busy with the issue" \
  'grep -qE "^busy [0-9]+ 12\$" "$st/workers/w12.state"'
check "the meta holds the facts" '[ "$(meta issue w12)" = 12 ] && [ "$(meta kind w12)" = worker ] &&
  [ "$(meta timebox w12)" = 5400 ] && [ "$(meta branch w12)" = issue-12 ] &&
  [ "$(meta handle w12)" = %1 ] && [ "$(meta worktree w12)" = "$tmp/wt12" ] &&
  [ "$(meta base w12)" = main ] && [ -n "$(meta started w12)" ]'
check "the guard config carries the LIMITS paths" \
  'c="$st/guard/w12.conf"; grep -qx "role=worker" "$c" && grep -qx "write=src/ tests/" "$c" &&
   grep -qx "deny=src/gen" "$c" && grep -qx "root=$tmp/wt12" "$c"'
check "the session has all four hooks" \
  '[ "$(jq -r ".hooks | keys | join(\" \")" "$st/workers/w12.settings.json")" = \
     "PreToolUse SessionEnd Stop UserPromptSubmit" ]'
check "the agent got the settings and a prompt naming the Brief" \
  'a="$fake/agent.args"
   [ "$(sed -n 1p "$a")" = --settings ] && grep -q "Brief is the file $b" "$a"'
check "no bypass flag was added" '! grep -qiE "dangerous|bypass|permission|yolo" "$fake/agent.args"'
check "the session knows which worker it is" \
  'e="$fake/agent.env"
   grep -qx "DISPATCH_WORKER=w12" "$e" && grep -qx "DISPATCH_ROLE=worker" "$e" &&
   grep -qx "DISPATCH_GUARD_CONFIG=$st/guard/w12.conf" "$e"'
check "the main checkout is recorded as trusted" \
  'j="$HOME/.claude.json"
   [ "$(jq -r --arg p "$repo" ".projects[\$p].hasTrustDialogAccepted" "$j")" = true ]'
check "the worktree stays clean, so teardown can remove it" \
  '[ -z "$(git -C "$tmp/wt12" status --porcelain)" ]'
guard() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"cwd":"%s"}' "$1" "$tmp/wt12" |
  sh -c "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$st/workers/w12.settings.json")" \
  >/dev/null 2>&1; }
guard "gh pr merge 5"; rc=$?; check "the installed guard denies a merge" '[ "$rc" -eq 2 ]'
guard "npm test"; rc=$?; check "and allows the gate" '[ "$rc" -eq 0 ]'

# 2. Already running is an error; a worker whose terminal is gone is relaunched on its worktree.
before=$(opened); start --brief "$b"
check "a running worker is not started twice" \
  '[ "$rc" -eq 1 ] && says "already running" && [ "$(opened)" = "$before" ]'
: > "$fake/panes"; echo keep > "$tmp/wt12/kept.txt"; start --brief "$b"
check "a gone worker is relaunched on the same worktree" \
  '[ "$rc" -eq 0 ] && [ -f "$tmp/wt12/kept.txt" ] && [ "$(meta handle w12)" = %1 ]'
cp "$HOME/.claude.json" "$tmp/trust.before"; rm "$tmp/wt12/kept.txt"
check "trust already recorded is not rewritten" 'cmp -s "$HOME/.claude.json" "$tmp/trust.before"'

# 3. A start that is not confirmed is a failed start and leaves no worker.
reset; brief 13; echo stuck > "$fake/agent-mode"
out=$(cd "$repo" && DISPATCH_START_WAIT=1 "$here/start.sh" --brief "$b" 2>&1); rc=$?
check "an agent stuck on a screen is a failed start" \
  '[ "$rc" -eq 1 ] && says "failed start of w13" && says "did not report busy within 1 s"'
check "it leaves no record behind" \
  'w="$st/workers/w13"; [ ! -e "$w.meta" ] && [ ! -e "$w.state" ] && [ ! -e "$st/guard/w13.conf" ]'
check "and names the terminal left open" 'says "tmux %1 is left open"'

# 4. The WIP limit: default 3, a rule line changes it, scouts and relaunches do not count.
reset; for i in 21 22 23; do brief $i; start --brief "$b"; done
check "three workers start" '[ "$rc" -eq 0 ] && [ "$(ls "$st/workers" | grep -c meta)" -eq 3 ]'
before=$(opened); brief 24; start --brief "$b"
check "the fourth is queued with 75 and nothing is opened" \
  '[ "$rc" -eq 75 ] && says "^queued: 3 workers" && [ "$(opened)" = "$before" ] &&
   [ ! -e "$st/workers/w24.meta" ] && [ ! -d "$tmp/wt24" ]'
start --brief "$b" --scout --id s24
check "a scout does not count against the limit" \
  '[ "$rc" -eq 0 ] && [ "$(meta kind s24)" = scout ] && [ "$(meta branch s24)" = scout-s24 ]'
: > "$fake/panes"; brief 21; start --brief "$b"
check "a relaunch does not count itself" '[ "$rc" -eq 0 ]'
printf 'WIP-limit: 1\n' > "$repo/AGENTS.md"; g add -A; g commit -q -m rules
reset; brief 31; start --brief "$b"; brief 32; start --brief "$b"
check "the WIP-limit rule line is honoured" '[ "$rc" -eq 75 ] && says "limit is 1"'

# 5. A Brief with a field it cannot read is not Ready.
reset
for edit in '/^TIMEBOX/d' 's/write=[^;]*;/;/' 's/ BASE main//' 's/WORKTREE.*//' \
  's/^TIMEBOX  90m/TIMEBOX  soon/' 's/^ISSUE #41/ISSUE 41/'; do
  brief 41 "$edit"; start --brief "$b"
  check "Brief edit $edit is refused" '[ "$rc" -eq 1 ] && says "not Ready" && [ "$(opened)" = 0 ]'
done
brief 41 's/90m/2h/'; start --brief "$b"
check "a TIMEBOX in hours is read" '[ "$rc" -eq 0 ] && [ "$(meta timebox w41)" = 7200 ]'
start --brief "$tmp/none"; check "a missing Brief is an error" '[ "$rc" -eq 1 ]'
start --brief "$b" --agent other; check "an unknown agent is usage" '[ "$rc" -eq 1 ]'
start --brief "$b" --id "../x"; check "an id with a path is usage" '[ "$rc" -eq 1 ]'

# 6. The hooks: they record the turn, and are inert outside a worker.
hook() {  # state [worker]
  (cd "$tmp" && DISPATCH_STATE="$st" DISPATCH_WORKER="${2-w41}" "$here/start.sh" --hook "$1")
}
hook idle; rc=$?; out=$(cat "$st/workers/w41.state")
check "the turn's end is recorded as idle" '[ "$rc" -eq 0 ] && says "^idle [0-9]* 41\$"'
hook ended; out=$(cat "$st/workers/w41.state")
check "the session's end is recorded" 'says "^ended "'
hook bogus; out=$(cat "$st/workers/w41.state")
check "an unknown state changes nothing" 'says "^ended "'
hook idle nobody; rc=$?
check "an unknown worker writes nothing" '[ "$rc" -eq 0 ] && [ ! -e "$st/workers/nobody.state" ]'
(cd "$tmp" && "$here/start.sh" --hook busy); rc=$?
check "outside a worker it does nothing" '[ "$rc" -eq 0 ]'

# 7. herdr carries a worker the same way.
reset; brief 51
out=$(cd "$repo" && DISPATCH_TERM=herdr "$here/start.sh" --brief "$b" 2>&1); rc=$?
check "a worker starts in a herdr pane" \
  '[ "$rc" -eq 0 ] && says "herdr=w1:p9" && [ "$(meta term w51)" = herdr ] &&
   grep -q "^pane split --current --direction right --cwd $tmp/wt51 --no-focus" "$fake/term.calls"'
out=$(cd "$repo" && DISPATCH_TERM=screen "$here/start.sh" --brief "$b" 2>&1); rc=$?
check "an unknown terminal is an error" '[ "$rc" -eq 1 ] && says "unknown DISPATCH_TERM"'

# 8. Codex: its hooks are user-level and trusted once; without them nothing is started.
export CODEX_HOME="$tmp/codex"; reset; brief 61; start --brief "$b" --agent codex
check "Codex with no hooks installed is refused before any session" \
  '[ "$rc" -eq 1 ] && says "start.sh --codex-hooks" && says "not seen denying" &&
   [ "$(opened)" = 0 ]'
mkdir -p "$CODEX_HOME"; (cd "$repo" && "$here/start.sh" --codex-hooks) > "$CODEX_HOME/hooks.json"
check "--codex-hooks prints hooks that are inert outside a worker" \
  'jq -r ".hooks.PreToolUse[0].hooks[0].command" "$CODEX_HOME/hooks.json" |
     grep -q "^\[ -z \"\$DISPATCH_GUARD_CONFIG\" \] || "'
start --brief "$b" --agent codex
check "Codex with its hooks installed starts" \
  '[ "$rc" -eq 0 ] && says "agent=codex" && [ "$(meta agent w61)" = codex ] &&
   grep -qE "^busy [0-9]+ 61\$" "$st/workers/w61.state"'
check "the worktree is recorded as trusted for Codex" \
  'grep -qxF "[projects.\"$tmp/wt61\"]" "$CODEX_HOME/config.toml"'
check "Codex got only the prompt" '[ "$(wc -l < "$fake/agent.args")" -eq 1 ]'
: > "$fake/panes"; start --brief "$b" --agent codex
check "trust is recorded once" '[ "$(grep -c "wt61" "$CODEX_HOME/config.toml")" -eq 1 ]'

echo "test-start: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
