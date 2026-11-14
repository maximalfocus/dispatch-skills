#!/usr/bin/env bash
# size-gate.sh — CONSTITUTION Article 6: line caps per skill and a 100-character line width.
# Width applies to skills/, CLAUDE.md, and CONSTITUTION.md outside the shared Articles 1–5
# (those are byte-identical to the family reference and are not rewrapped here).
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0
cap() {
  [ -f "$1" ] || { echo "MISSING: $1"; fail=1; return; }
  n=$(wc -l < "$1" | tr -d ' ')
  [ "$n" -le "$2" ] || { echo "OVER: $1 ($n > $2 lines)"; fail=1; }
}
cap skills/dispatch/SKILL.md 220
cap skills/dispatch-aide/SKILL.md 200
cap skills/dispatch-worker/SKILL.md 100
cap skills/dispatch-evolve/SKILL.md 100
scripts=$(find scripts skills/*/scripts -maxdepth 1 -type f ! -name 'test-*' 2>/dev/null | sort)
nscripts=$(printf '%s\n' "$scripts" | grep -c .)
[ "$nscripts" -le 12 ] || { echo "OVER: scripts/ has $nscripts files (> 16)"; fail=1; }
slines=$(cat $scripts | wc -l | tr -d ' ')
[ "$slines" -le 2500 ] || { echo "OVER: scripts/ total $slines lines (> 2500)"; fail=1; }
width() {  # file, skip_shared(0/1); counts characters, not bytes
  perl -CSD -ne '
    BEGIN { ($f, $skip) = (shift @ARGV, shift @ARGV); }
    $s = 1 if $skip && /^## Article 1 /; $s = 0 if /^## Article 6 /;
    chomp; if (!$s && length($_) > 100) { printf "OVER: %s:%d (%d chars)\n", $f, $., length; $bad = 1 }
    END { exit($bad ? 1 : 0) }' "$1" "$2" "$1" || fail=1
}
for f in skills/*/SKILL.md CLAUDE.md; do width "$f" 0; done
width CONSTITUTION.md 1
[ "$fail" -eq 0 ] && echo PASS || exit 1
