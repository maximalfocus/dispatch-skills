#!/usr/bin/env bash
# validate.sh — CONSTITUTION Article 7, structural part: front matter, required sections, and
# cross-references that resolve. The semantic part is judgment and is not checked here.
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0
bad() { echo "FAIL: $*"; fail=1; }
for f in skills/*/SKILL.md; do
  name=$(basename "$(dirname "$f")")
  head -1 "$f" | grep -qx -- '---' || bad "$f: no front matter"
  grep -qx "name: $name" "$f" || bad "$f: front matter name is not '$name'"
  grep -q '^description:' "$f" || bad "$f: no description"
  grep -q '^## First: read the constitution' "$f" || bad "$f: no '## First: read the constitution'"
  grep -q '^## Never' "$f" || bad "$f: no '## Never' list"
  grep -q '^## After completion' "$f" || bad "$f: no '## After completion'"
  grep -q 'dispatch-evolve' "$f" || bad "$f: does not route lessons to /dispatch-evolve"
  # every backticked repo path must exist
  grep -o '`\(skills\|scripts\)/[A-Za-z0-9_./-]*`' "$f" | tr -d '`' | sort -u | while read -r p; do
    [ -e "$p" ] || { echo "FAIL: $f: reference $p does not exist"; exit 1; }
  done || fail=1
done
grep -q '^## Hand-off formats' skills/dispatch/SKILL.md || bad "dispatch: no Hand-off formats section"
for fmt in 'HANDBACK issue=' 'ACCEPT-REQ issue=' 'ACCEPT issue=' 'ASK kind=' '**Stage report**' 'XPROJ from='; do
  grep -qF "$fmt" skills/dispatch/SKILL.md || bad "dispatch: format '$fmt' missing"
done
grep -q '^## GATE' skills/dispatch-evolve/SKILL.md || bad "dispatch-evolve: no GATE checkpoint"
[ "$fail" -eq 0 ] && echo PASS || exit 1
