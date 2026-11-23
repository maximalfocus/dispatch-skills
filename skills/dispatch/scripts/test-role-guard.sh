#!/usr/bin/env bash
# test-role-guard.sh — hermetic tests for role-guard.sh: hand-written configs and tool calls fed
# on stdin, as the agent's PreToolUse hook would. No network. Exit 0 when every case passes.
set -u
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); }
no() { fail=$((fail + 1)); echo "FAIL: $*"; }

unset DISPATCH_STATE DISPATCH_ROLE DISPATCH_GUARD_CONFIG CLAUDE_PROJECT_DIR
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
repo="$tmp/project"; git init -q -b main "$repo"; mkdir -p "$repo/src" "$repo/docs" "$tmp/out"
conf() {  # role [extra lines] — write that role's config and use it
  { echo "role=$1"; echo "root=$repo"; shift; [ $# -eq 0 ] || printf '%s\n' "$@"; } > "$tmp/conf"
}
guard() {  # tool input-json — run the hook on one tool call
  out=$(jq -n --arg t "$1" --argjson i "$2" --arg d "$repo" \
    '{hook_event_name: "PreToolUse", tool_name: $t, tool_input: $i, cwd: $d}' |
    (cd "$repo" && "$here/role-guard.sh" --config "$tmp/conf" 2>&1)); rc=$?
}
bash_call() { guard Bash "$(jq -n --arg c "$1" '{command: $c}')"; }
write_call() { guard "${2:-Write}" "$(jq -n --arg p "$1" '{file_path: $p}')"; }
denied() { if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "denied"; then ok
  else no "$1 should be denied (rc=$rc out=$out)"; fi; }
allowed() { if [ "$rc" -eq 0 ] && [ -z "$out" ]; then ok
  else no "$1 should be allowed (rc=$rc out=$out)"; fi; }
says() { if printf '%s' "$out" | grep -q -- "$1"; then ok; else no "expected '$1' in: $out"; fi; }

# 1. Dispatcher: no built-in delegation, no verdicts, no writes outside its paths.
conf dispatcher "write=.dispatch/ briefs/ AGENTS.md"
for t in Task Agent Workflow; do guard "$t" '{"prompt":"do it"}'; denied "dispatcher $t"; done
says "role-guard\[dispatcher\]: denied: built-in delegation"
guard Read '{"file_path":"/etc/hosts"}'; allowed "dispatcher reading"
bash_call 'gh issue comment 9 --body "ACCEPT issue=#9 head=abc verdict=PASS evidence=x"'
denied "dispatcher posting a verdict"; says "verdicts are the aide's"
bash_call 'gh issue comment 9 --body "ACCEPT-REQ issue=#9 head=abc env=staging tier=1"'
allowed "dispatcher posting an acceptance request"
bash_call 'gh issue comment 9 --body "the aide will ACCEPT this later"'
allowed "ACCEPT in the middle of a line"
bash_call "gh issue comment 9 --body \"\$(cat <<'EOF'
note
ACCEPT issue=#9 head=abc verdict=PASS evidence=x
EOF
)\""; denied "a verdict line inside a heredoc body"
bash_call 'gh pr comment 9 --body $'"'"'note\nACCEPT issue=#9 head=a verdict=PASS evidence=x'"'"
denied "a verdict line after an escaped newline"
printf 'note\nACCEPT issue=#9 head=abc verdict=FAIL evidence=x\n' > "$repo/body.md"
echo "ACCEPT-REQ issue=#9 head=abc env=s tier=1" > "$repo/req.md"
bash_call 'gh issue comment 9 --body-file body.md'; denied "a verdict in --body-file"
bash_call 'gh issue comment 9 -F body.md'; denied "a verdict in -F"
bash_call 'gh issue comment 9 --body-file=body.md'; denied "a verdict in --body-file="
bash_call 'gh api repos/o/r/issues/9/comments -F body=@body.md'; denied "a verdict in body=@file"
bash_call 'gh issue comment 9 --body-file req.md'; allowed "a request in --body-file"
bash_call 'gh pr merge 5 --squash'; allowed "the dispatcher merging (land.sh does it)"
bash_call 'echo "ACCEPT is a word" > notes'; allowed "ACCEPT text with no gh call"
write_call "$repo/.dispatch/board.md"; allowed "the board"
write_call "briefs/12.md"; allowed "a Brief by relative path"
write_call "$repo/AGENTS.md" Edit; allowed "the project's rules"
write_call "$repo/src/app.py"; denied "dispatcher writing product code"
says "outside the paths this dispatcher may write"
write_call "$repo/src/app.py" Edit; denied "dispatcher editing product code"
guard NotebookEdit "$(jq -n --arg p "$repo/src/n.ipynb" '{notebook_path: $p}')"
denied "dispatcher editing a notebook"
guard Write '{}'; denied "a write with no path"

# 2. Worker: no merge, no force-push, no rebase, no verdict, no write outside LIMITS.
conf worker "write=src/ tests/ docs/*.md" "deny=src/secrets/ src/gen"
for c in 'gh pr merge 5 --squash' 'cd x && gh pr merge' 'gh -R o/r pr merge 5' \
  'bash -c "gh pr merge 5"' '/opt/bin/gh pr merge 5' \
  'gh api -X PUT repos/o/r/pulls/5/merge' 'echo ok; gh pr merge 5'; do
  bash_call "$c"; denied "worker: $c"
done
says "role-guard\[worker\]: denied: gh pr merge"
for c in 'git push --force' 'git push -f origin feat' 'git push --force-with-lease' \
  'git -C wt push -uf origin feat' 'git push origin +feat' 'git push origin "+HEAD:feat"' \
  'git rebase main' 'git -c x=y rebase -i HEAD~2' 'git pull --rebase' 'git pull -r origin main' \
  'git fetch && git rebase origin/main'; do
  bash_call "$c"; denied "worker: $c"
done
for c in 'git push -u origin feat' 'git push --follow-tags' 'git pull --rebase=false' \
  'git merge origin/main' 'git log --grep rebase' 'gh pr create --fill' 'gh pr view 5' \
  'git commit -m "explain why we never force or rebase"' 'npm test'; do
  bash_call "$c"; allowed "worker: $c"
done
bash_call 'gh pr comment 5 --body "ACCEPT issue=#9 head=abc verdict=PASS evidence=x"'
denied "worker posting a verdict"
bash_call 'gh pr comment 5 --body "HANDBACK issue=#9 pr=#5 head=abc status=done"'
allowed "worker posting a Hand-back"
write_call "$repo/src/app.py"; allowed "worker in its LIMITS"
write_call "tests/test_app.py" Edit; allowed "worker's tests by relative path"
write_call "$repo/docs/guide.md"; allowed "a glob entry"
write_call "$repo/docs/guide.txt"; denied "outside a glob entry"
write_call "$repo/src/secrets/key.txt"; denied "the no-write list"; says "no-write list"
write_call "$repo/src/gen"; denied "a no-write entry itself"
write_call "$repo/src/generic.py"; allowed "a name that only starts like a no-write entry"
write_call "$repo/README.md"; denied "outside LIMITS"
write_call "$tmp/out/x.txt"; denied "outside the worktree"
write_call "$repo/src/../README.md"; denied "a path with .."; says "'\.\.'"
ln -s "$tmp/out" "$repo/src/link"; write_call "$repo/src/link/x.txt"
denied "a write through a symlink out of LIMITS"
guard apply_patch "$(jq -n '{patch: "*** Begin Patch\n*** Update File: src/a.py\n*** End Patch"}')"
allowed "a patch inside LIMITS"
guard apply_patch "$(jq -n '{patch: "*** Begin Patch\n*** Add File: README.md\n*** End Patch"}')"
denied "a patch outside LIMITS"
guard Task '{"prompt":"explore"}'; allowed "a worker's own subagent"
guard shell '{"command":["bash","-lc","gh pr merge 5"]}'; denied "a command given as an array"

# 3. Aide: no merge, writes only its kit and evidence; verdicts are its own.
conf aide "write=.claude/skills/verify-app/ evidence/"
bash_call 'gh pr merge 5'; denied "aide merging"
bash_call 'gh issue comment 9 --body "ACCEPT issue=#9 head=abc verdict=PASS evidence=x"'
allowed "the aide posting its verdict"
bash_call 'git rebase main'; allowed "aide: only the worker's git rules are the worker's"
write_call "$repo/evidence/run1.png"; allowed "aide evidence"
write_call "$repo/.claude/skills/verify-app/SKILL.md"; allowed "aide kit"
write_call "$repo/src/app.py"; denied "aide writing product code"

# 4. Fail closed: no config, an unreadable one, an unknown role, an unreadable call.
conf worker "write=src/"
call='{"tool_name":"Read","tool_input":{"file_path":"x"}}'
hook() {  # call-json [hook args]
  out=$(printf '%s' "$1" | (cd "$repo" && shift && "$here/role-guard.sh" "$@" 2>&1)); rc=$?
}
hook "$call" --config "$tmp/conf"; allowed "a harmless call with a good config"
hook "$call"; denied "no config at all"; says "role-guard\[?\]: denied: no guard config"
hook "$call" --config "$tmp/missing"; denied "a missing config"; says "missing or unreadable"
printf 'role=boss\n' > "$tmp/conf"; hook "$call" --config "$tmp/conf"
denied "an unknown role"; says "unknown role 'boss'"
: > "$tmp/conf"; hook "$call" --config "$tmp/conf"; denied "an empty config"
conf worker "write=src/"
hook 'not json' --config "$tmp/conf"; denied "an unreadable tool call"
hook '' --config "$tmp/conf"; denied "an empty tool call"
hook '{"tool_input":{}}' --config "$tmp/conf"; denied "a call with no tool name"
printf 'role=worker\nroot=%s\nwrite=src/' "$repo" > "$tmp/conf"
write_call "$repo/src/a.py"; allowed "a config with no final newline"
write_call "$repo/b.py"; denied "and it still guards"
conf worker; write_call "$repo/src/a.py"; denied "a role with no write list writes nothing"
# The config can also come from the environment, or from the state dir by role.
out=$(printf '%s' "$call" | (cd "$repo" && DISPATCH_GUARD_CONFIG="$tmp/conf" \
  "$here/role-guard.sh" 2>&1)); rc=$?; allowed "DISPATCH_GUARD_CONFIG"
mkdir -p "$repo/.dispatch/state/guard"; cp "$tmp/conf" "$repo/.dispatch/state/guard/worker.conf"
out=$(printf '%s' "$call" | (cd "$repo" && DISPATCH_ROLE=worker "$here/role-guard.sh" 2>&1)); rc=$?
allowed "DISPATCH_ROLE finds the config in the state dir"
out=$(printf '%s' "$call" | (cd "$repo" && DISPATCH_ROLE=aide "$here/role-guard.sh" 2>&1)); rc=$?
denied "DISPATCH_ROLE with no config for that role"

# 5. --probe goes through the hook the session's settings install.
probe() { out=$(cd "$repo" && "$here/role-guard.sh" --probe "$@" 2>&1); rc=$?; }
settings() {  # matcher command — install one PreToolUse hook
  mkdir -p "$repo/.claude"
  jq -n --arg m "$1" --arg c "$2" '{hooks: {PreToolUse: [{matcher: $m, hooks:
    [{type: "command", command: $c}]}]}}' > "$repo/.claude/settings.local.json"
}
is() { if [ "$rc" -eq "$2" ]; then ok; else no "$1 (rc=$rc out=$out)"; fi; }
probe worker; is "nothing installed fails the probe" 1; says "no role-guard hook is installed"
conf worker "write=src/"
settings "" "'$here/role-guard.sh' --config '$tmp/conf'"
probe worker; is "an installed, configured hook passes" 0; says "denied a forbidden act for worker"
probe aide; is "the wrong role's config fails the probe" 1; says "did not deny as aide"
probe dispatcher; is "a worker config does not pass as dispatcher" 1
settings "Edit|Write" "'$here/role-guard.sh' --config '$tmp/conf'"
probe worker; is "a matcher that misses Bash fails the probe" 1
settings "Bash|Edit|Write" "'$here/role-guard.sh' --config '$tmp/conf'"
probe worker; is "a matcher that names Bash passes" 0
settings "*" "'$here/role-guard.sh' --config '$tmp/gone'"
probe worker; is "a hook with no config denies, but not as that role" 1
settings "*" "true # role-guard"
probe worker; is "a hook that allows everything fails the probe" 1; says "did not deny"
conf dispatcher "write=.dispatch/"
settings "" "'$here/role-guard.sh' --config '$tmp/conf'"
probe dispatcher; is "the dispatcher's probe passes" 0
rm "$repo/.claude/settings.local.json"
jq -n --arg c "'$here/role-guard.sh' --config '$tmp/conf'" '{hooks: {PreToolUse: [{hooks:
  [{type: "command", command: $c}]}]}}' > "$tmp/alt.json"
probe dispatcher --settings "$tmp/alt.json"; is "--settings names another settings file" 0
probe boss; is "an unknown role is a usage error" 1

echo "test-role-guard: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
