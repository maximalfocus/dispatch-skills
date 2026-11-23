#!/usr/bin/env bash
# test-land.sh — hermetic tests for land.sh: a bare "remote" holding the base branch and the PR
# heads as refs/pull/<n>/head, and a fake gh serving fixture JSON. No network. Exit 0 on all pass.
set -u
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
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
commit() { g add -A && g commit -q -m "$1"; }
g remote add origin "$origin"
mkdir -p "$repo/scripts"
echo a > "$repo/a.txt"; echo b > "$repo/b.txt"; echo gate > "$repo/scripts/gate.sh"
printf '# rules\n\nGate-files: scripts/, *.yml\n' > "$repo/AGENTS.md"
commit base; g push -q origin main

pr_branch() {  # number file — a branch off main changing one file, published as that PR's head
  g checkout -q -b "pr$1" main
  mkdir -p "$(dirname "$repo/$2")"; echo "change $1" >> "$repo/$2"; commit "pr $1"
  g push -q origin "pr$1" "pr$1:refs/pull/$1/head"
  g checkout -q main
}
pr_branch 10 a.txt; head10=$(g rev-parse pr10)
pr_branch 11 scripts/gate.sh; head11=$(g rev-parse pr11)

cat > "$fake/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE/calls"
case "$*" in
  pr\ view*) cat "$FAKE/pr.json" ;;
  pr\ merge*) echo "$*" >> "$FAKE/merged"; exit "$(cat "$FAKE/merge-rc")" ;;
  issue\ view*) cat "$FAKE/issue.json" ;;
  *DELETE*) echo "$*" >> "$FAKE/deleted" ;;
  *rules/branches*) [ -f "$FAKE/rules.json" ] || exit 1; cat "$FAKE/rules.json" ;;
  *branches/*) [ -f "$FAKE/branch.json" ] || exit 1; cat "$FAKE/branch.json" ;;
  *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$fake/gh"
export FAKE="$fake" DISPATCH_GH="$fake/gh" DISPATCH_REPO=o/r
prjson() {  # head [checks-json] [jq-overrides]
  jq -n --arg h "$1" --argjson c "${2:-$green}" '{state: "OPEN", isDraft: false,
    mergeable: "MERGEABLE", headRefOid: $h, headRefName: "feat", baseRefName: "main",
    isCrossRepository: false, statusCheckRollup: $c}' | jq "${3:-.}" > "$fake/pr.json"
}
green='[{"__typename":"CheckRun","name":"gates","status":"COMPLETED","conclusion":"SUCCESS"}]'
protect() { jq -n --argjson c "$1" '{protection: {required_status_checks: {contexts: $c}}}' \
  > "$fake/branch.json"; }
reset() { rm -f "$fake/merged" "$fake/deleted" "$fake/calls"; echo 0 > "$fake/merge-rc"
  echo '[]' > "$fake/rules.json"; protect '["gates"]'; prjson "$head10"; }
land() { out=$(cd "$repo" && "$here/land.sh" "$@" 2>&1); rc=$?; }
merged() { [ -f "$fake/merged" ]; }
says() { printf '%s' "$out" | grep -q -- "$1"; }

# 1. A green PR at the handed-back head lands, pinned to the full SHA, and its branch goes.
reset; land 10 --head "$head10"
check "a green PR lands" '[ "$rc" -eq 0 ] && says "landed PR #10"'
check "the merge is a squash pinned to the head" \
  'grep -q -- "--squash --match-head-commit $head10" "$fake/merged"'
check "the remote branch is deleted" 'grep -q "git/refs/heads/feat" "$fake/deleted"'
check "no temporary ref is left" '[ -z "$(g for-each-ref refs/dispatch)" ]'
reset; land "#10" --head "$(printf '%s' "$head10" | cut -c 1-8)"
check "a short SHA still pins the full head" \
  '[ "$rc" -eq 0 ] && grep -q -- "--match-head-commit $head10" "$fake/merged"'
reset; prjson "$head10" "$green" '.isCrossRepository = true'; land 10 --head "$head10"
check "a fork's branch is not deleted" '[ "$rc" -eq 0 ] && [ ! -f "$fake/deleted" ]'

# 2. Usage errors never reach GitHub.
reset; land 10; check "no --head is a usage error" '[ "$rc" -eq 1 ] && [ ! -f "$fake/calls" ]'
land 10 --head abc12; check "a 5-digit SHA is refused as usage" '[ "$rc" -eq 1 ]'
land 10 --head "$head10" --gate-change; check "an empty --gate-change is usage" '[ "$rc" -eq 1 ]'
land x --head "$head10"; check "a non-numeric PR is usage" '[ "$rc" -eq 1 ] && ! merged'

# 3. The live PR decides, not the Hand-back.
reset; land 10 --head "$head11"
check "another head is refused" '[ "$rc" -eq 2 ] && says "is not the handed-back" && ! merged'
reset; prjson "$head10" "$green" '.isDraft = true'; land 10 --head "$head10"
check "a draft is refused" '[ "$rc" -eq 2 ] && says "is a draft" && ! merged'
reset; prjson "$head10" "$green" '.state = "MERGED"'; land 10 --head "$head10"
check "a PR that is not open is refused" '[ "$rc" -eq 2 ] && says "not open" && ! merged'
for m in CONFLICTING UNKNOWN; do
  reset; prjson "$head10" "$green" ".mergeable = \"$m\""; land 10 --head "$head10"
  check "mergeable=$m is refused" '[ "$rc" -eq 2 ] && says "as $m" && ! merged'
done
reset; echo 'not json' > "$fake/pr.json"; land 10 --head "$head10"
check "an unreadable PR is an error, not a merge" '[ "$rc" -eq 1 ] && ! merged'
reset; g push -q -f origin "pr11:refs/pull/10/head"; land 10 --head "$head10"
check "a head that moved under us is refused" '[ "$rc" -eq 2 ] && says "head moved" && ! merged'
g push -q -f origin "pr10:refs/pull/10/head"

# 4. Required checks: every name must have reported SUCCESS at this head.
reset; prjson "$head10" '[]'; land 10 --head "$head10"
check "a required check that never reported is refused" \
  '[ "$rc" -eq 2 ] && says "gates.* never reported" && ! merged'
for c in FAILURE SKIPPED NEUTRAL CANCELLED; do
  reset; prjson "$head10" "$(printf '%s' "$green" | jq ".[0].conclusion = \"$c\"")"
  land 10 --head "$head10"
  check "conclusion $c is not green" '[ "$rc" -eq 2 ] && says "gates.* is $c" && ! merged'
done
reset; prjson "$head10" "$(printf '%s' "$green" | jq '.[0] |= (.status = "IN_PROGRESS"
  | .conclusion = null)')"; land 10 --head "$head10"
check "a running check is not green" '[ "$rc" -eq 2 ] && says "is IN_PROGRESS" && ! merged'
reset; prjson "$head10" "$(printf '%s' "$green" | jq '. + [.[0] | .conclusion = "FAILURE"]')"
land 10 --head "$head10"
check "one red run among two of a name is refused" '[ "$rc" -eq 2 ] && ! merged'
reset; protect '["gates","ctx"]'
prjson "$head10" "$(printf '%s' "$green" | jq '. + [{"__typename":"StatusContext",
  "context":"ctx","state":"PENDING"}]')"; land 10 --head "$head10"
check "a pending commit status is refused" '[ "$rc" -eq 2 ] && says "ctx.* is PENDING"'
prjson "$head10" "$(printf '%s' "$green" | jq '. + [{"__typename":"StatusContext",
  "context":"ctx","state":"SUCCESS"}]')"; land 10 --head "$head10"
check "a green status and a green run land" '[ "$rc" -eq 0 ] && merged'
reset; protect '[]'; land 10 --head "$head10"
check "no known required check is refused" \
  '[ "$rc" -eq 2 ] && says "no required check is known" && ! merged'
reset; protect '[]'; echo '[{"type":"required_status_checks","parameters":
  {"required_status_checks":[{"context":"lint"}]}}]' > "$fake/rules.json"; land 10 --head "$head10"
check "a ruleset's required check counts" '[ "$rc" -eq 2 ] && says "lint.* never reported"'
reset; rm -f "$fake/branch.json" "$fake/rules.json"; land 10 --head "$head10"
check "unreadable protection is noted and excuses nothing" \
  '[ "$rc" -eq 2 ] && says "note: cannot read" && says "no required check is known" && ! merged'

# 5. The project's own Required-checks line, read from the base branch, counts too.
printf 'Required-checks: gates, build / test\n' >> "$repo/AGENTS.md"; commit rules
g push -q origin main
reset; protect '[]'; land 10 --head "$head10"
check "a rules-line check that never reported is refused" \
  '[ "$rc" -eq 2 ] && says "build / test.* never reported" && ! merged'
both=$(printf '%s' "$green" | jq '. + [.[0] | .name = "build / test"]')
reset; protect '[]'; prjson "$head10" "$both"; land 10 --head "$head10"
check "the rules line alone can make a PR landable" '[ "$rc" -eq 0 ] && merged'
green=$both

# 6. Update needed: the base changed a file the PR also changes.
echo other >> "$repo/b.txt"; commit "base moves elsewhere"; g push -q origin main
reset; land 10 --head "$head10"
check "a base change to another file needs no update" '[ "$rc" -eq 0 ] && merged'
echo clash >> "$repo/a.txt"; commit "base touches a.txt"; g push -q origin main
reset; land 10 --head "$head10"
check "a base change to the PR's file is update needed" \
  '[ "$rc" -eq 2 ] && says "update needed: main changed a.txt" && ! merged'
g checkout -q pr10; g merge -q --no-edit -X ours main >/dev/null
g push -q -f origin "pr10:refs/pull/10/head"
g checkout -q main; head10=$(g rev-parse pr10)
reset; land 10 --head "$head10"
check "merging the base into the branch clears it" '[ "$rc" -eq 0 ] && merged'

# 7. Gate files need the aide's evidence on an open issue.
issue() { jq -n --arg s "$1" --argjson n "$2" '{state: $s, comments: [range($n) | {body: "e"}]}' \
  > "$fake/issue.json"; }
g checkout -q pr11; g merge -q --no-edit main; g push -q origin "pr11:refs/pull/11/head"
g checkout -q main; head11=$(g rev-parse pr11)
reset; prjson "$head11"; land 11 --head "$head11"
check "a PR touching a gate file is refused" \
  '[ "$rc" -eq 2 ] && says "changes gate files (scripts/gate.sh)" && ! merged'
issue CLOSED 1; land 11 --head "$head11" --gate-change 5
check "a closed gate-change issue is refused" '[ "$rc" -eq 2 ] && says "is not open" && ! merged'
issue OPEN 0; land 11 --head "$head11" --gate-change 5
check "an issue with no evidence is refused" '[ "$rc" -eq 2 ] && says "no evidence" && ! merged'
issue OPEN 1; land 11 --head "$head11" --gate-change "#5"
check "an open issue with evidence lands it" '[ "$rc" -eq 0 ] && merged'
reset; prjson "$head10"; land 10 --head "$head10" --gate-change 5
check "--gate-change on an ordinary PR reads no issue" \
  '[ "$rc" -eq 0 ] && ! grep -q "issue view" "$fake/calls"'

# 8. GitHub's own refusal is reported as a failure, never as landed.
reset; echo 1 > "$fake/merge-rc"; land 10 --head "$head10"
check "a refused merge exits 1" '[ "$rc" -eq 1 ] && says "GitHub refused" && ! says "^landed"'
check "and deletes no branch" '[ ! -f "$fake/deleted" ]'

echo "test-land: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
