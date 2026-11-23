#!/usr/bin/env bash
# land.sh — merge a PR only at the handed-back head, on facts read now (DESIGN.md §12). Run it in
# the project checkout.
#
#   land.sh <pr> --head <sha> [--gate-change <issue>]
#
# Refuses (exit 2, one "refused:" line per reason) unless all of these hold:
#   - the PR is open, not a draft, and GitHub reports it MERGEABLE
#   - its live head is <sha> (a prefix of 7 or more hex digits is enough)
#   - every required check reported SUCCESS at that head. Required names are GitHub's for the base
#     branch (protection and rulesets) plus the project's `Required-checks:` line (comma-separated,
#     in AGENTS.md or CLAUDE.md on the base branch). A name with no report is not green, a skipped
#     or neutral one is not green, and a base with no known required check at all is a refusal.
#   - no update is needed: since the PR's merge base, the base branch has not changed a file the PR
#     also changes. The worker repairs that by merging the base into its branch, never by a rebase.
#   - the PR touches no path on the project's `Gate-files:` line, or --gate-change names an open
#     issue holding at least one comment (whether that evidence is enough is judgment, not ours).
# Then it squash-merges pinned to the full head SHA and deletes the PR's branch on the remote.
# Exit: 0 landed · 2 refused · 1 the facts could not be read, or GitHub refused the merge.
# Env: DISPATCH_GH (gh), DISPATCH_REPO (owner/name), DISPATCH_REMOTE (origin).
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"
usage() { echo "usage: land.sh <pr> --head <sha> [--gate-change <issue>]" >&2; exit 1; }

pr=; want=; gate_issue=; gate_flag=0
while [ $# -gt 0 ]; do
  case $1 in
    --head) want=${2:-}; shift ;;
    --gate-change) gate_issue=${2:-}; gate_flag=1; shift ;;
    -*) usage ;;
    *) [ -z "$pr" ] || usage; pr=$1 ;;
  esac
  shift
done
pr=${pr#\#}; gate_issue=${gate_issue#\#}
case $pr in ''|*[!0-9]*) usage ;; esac
want=$(printf '%s' "$want" | tr 'A-F' 'a-f')
case $want in *[!0-9a-f]*) usage ;; esac
[ ${#want} -ge 7 ] && [ ${#want} -le 40 ] || usage
case $gate_issue in *[!0-9]*) usage ;; esac
[ "$gate_flag" -eq 0 ] || [ -n "$gate_issue" ] || usage

gh=${DISPATCH_GH:-gh}; remote=${DISPATCH_REMOTE:-origin}
command -v jq >/dev/null || { echo "land: jq is required" >&2; exit 1; }
git rev-parse --git-dir >/dev/null 2>&1 ||
  { echo "land: run inside the project's git checkout" >&2; exit 1; }
repo=${DISPATCH_REPO:-$($gh repo view --json nameWithOwner --jq .nameWithOwner)} || exit 1
refused=0
refuse() { echo "refused: $*"; refused=1; }

# 1. The PR as GitHub reports it now, never as the Hand-back described it.
fields=state,isDraft,mergeable,headRefOid,headRefName,baseRefName,isCrossRepository
json=$($gh pr view "$pr" --repo "$repo" --json "$fields,statusCheckRollup") &&
  printf '%s' "$json" | jq -e '(.headRefOid | type) == "string"' >/dev/null 2>&1 ||
  { echo "land: cannot read PR #$pr" >&2; exit 1; }
get() { printf '%s' "$json" | jq -r "$1"; }
state=$(get .state); live=$(get .headRefOid); base=$(get .baseRefName); branch=$(get .headRefName)
mergeable=$(get .mergeable)
[ "$state" = OPEN ] || refuse "PR #$pr is $state, not open"
[ "$(get .isDraft)" = false ] || refuse "PR #$pr is a draft"
[ "$mergeable" = MERGEABLE ] || refuse "GitHub reports PR #$pr as $mergeable, not MERGEABLE"
case $live in "$want"*) ;; *) refuse "live head $live is not the handed-back $want" ;; esac

# 2. The same two commits locally, so file facts come from git and have no API page limit.
ref="refs/dispatch/land-$pr"
trap 'git update-ref -d "$ref-base" 2>/dev/null; git update-ref -d "$ref-head" 2>/dev/null' EXIT
git fetch -q "$remote" "+refs/heads/$base:$ref-base" "+refs/pull/$pr/head:$ref-head" ||
  { echo "land: cannot fetch $base and PR #$pr from $remote" >&2; exit 1; }
[ "$(git rev-parse "$ref-head")" = "$live" ] || refuse "PR #$pr head moved while landing"

# 3. Required checks: the names come from the base branch, the states from this head.
api() {  # path filter — a source that cannot be read is noted; it adds no names, it excuses none
  local out
  out=$($gh api "$1" 2>/dev/null) && printf '%s' "$out" | jq -r "$2" 2>/dev/null ||
    echo "land: note: cannot read $1" >&2
}
required=$(
  { api "repos/$repo/branches/$base" '.protection.required_status_checks.contexts[]?'
    api "repos/$repo/rules/branches/$base" '.[] | select(.type == "required_status_checks")
      | .parameters.required_status_checks[].context'
    ds_rule "$ref-base" Required-checks | tr ',' '\n'
  } | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | sort -u)
rollup=$(get '.statusCheckRollup // [] | .[] | [(.name // .context // "?"),
  ((if .__typename == "StatusContext" then .state
    elif .status == "COMPLETED" then .conclusion else .status end) // "UNKNOWN")] | @tsv')
if [ -z "$required" ]; then
  refuse "no required check is known for $base: protect the branch, or add a" \
    "'Required-checks:' line to the project's rules"
fi
while IFS= read -r name; do
  [ -n "$name" ] || continue
  states=$(printf '%s\n' "$rollup" | awk -F'\t' -v n="$name" '$1 == n { print $2 }' |
    sort -u | tr '\n' ' ')
  case $states in
    '') refuse "required check '$name' never reported at $live" ;;
    'SUCCESS ') ;;
    *) refuse "required check '$name' is ${states% } at $live" ;;
  esac
done < <(printf '%s\n' "$required")

# 4. Update needed: the base moved past the merge base and changed a file the PR also changes.
mb=$(git merge-base "$ref-base" "$ref-head") ||
  { echo "land: PR #$pr shares no history with $base" >&2; exit 1; }
pr_files=$(git diff --no-renames --name-only "$mb" "$ref-head")
both=$(git diff --no-renames --name-only "$mb" "$ref-base" |
  grep -Fxf <(printf '%s\n' "$pr_files") | head -5 | tr '\n' ' ')
[ -z "$both" ] || refuse "update needed: $base changed ${both% } since the merge base; the" \
  "worker merges $base into its branch and hands back the new head"

# 5. Gate files: a PR that touches one lands only with the aide's evidence on an open issue.
gates=$(ds_rule "$ref-base" Gate-files | tr ', ' '\n\n' | grep -v '^$')
hit=
while IFS= read -r f; do
  [ -n "$f" ] && [ -n "$gates" ] || continue
  while IFS= read -r g; do
    g=${g%/}
    # shellcheck disable=SC2254  # the rule line holds glob patterns on purpose
    case $f in $g|$g/*) hit="$hit $f"; break ;; esac
  done < <(printf '%s\n' "$gates")
done < <(printf '%s\n' "$pr_files")
if [ -n "$hit" ]; then
  hit=$(printf '%s' "${hit# }" | cut -c 1-200)
  if [ -z "$gate_issue" ]; then
    refuse "PR #$pr changes gate files ($hit): pass --gate-change <issue> naming the open" \
      "issue that holds the aide's evidence"
  else
    gj=$($gh issue view "$gate_issue" --repo "$repo" --json state,comments) ||
      { echo "land: cannot read issue #$gate_issue" >&2; exit 1; }
    [ "$(printf '%s' "$gj" | jq -r .state)" = OPEN ] ||
      refuse "gate-change issue #$gate_issue is not open"
    [ "$(printf '%s' "$gj" | jq -r '.comments | length')" -gt 0 ] 2>/dev/null ||
      refuse "gate-change issue #$gate_issue holds no evidence comment"
  fi
fi

[ "$refused" -eq 0 ] || exit 2
$gh pr merge "$pr" --repo "$repo" --squash --match-head-commit "$live" ||
  { echo "land: GitHub refused the merge of PR #$pr at $live" >&2; exit 1; }
if [ "$(get .isCrossRepository)" = false ]; then
  $gh api -X DELETE "repos/$repo/git/refs/heads/$branch" >/dev/null 2>&1 ||
    echo "land: note: branch $branch was not deleted on the remote (already gone?)" >&2
fi
echo "landed PR #$pr at $live into $base"
