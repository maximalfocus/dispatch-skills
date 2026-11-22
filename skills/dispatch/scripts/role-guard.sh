#!/usr/bin/env bash
# role-guard.sh — one fail-closed PreToolUse hook for every role (DESIGN.md §12). It reads the tool
# call as JSON on stdin ({tool_name, tool_input, cwd}) and exits 2, with the reason on stderr, to
# deny it; exit 0 allows it. A tripwire for drift and mistakes, not a sandbox (DESIGN.md §13): it
# sees the file tools and the text of a shell command, not what a script does when it runs.
#
#   role-guard.sh [--config <file>]                      the hook
#   role-guard.sh --probe <role> [--settings <file>]     is the installed hook denying this role?
#
# Config: --config, else $DISPATCH_GUARD_CONFIG, else <state>/guard/$DISPATCH_ROLE.conf. Lines:
#   role=dispatcher|aide|worker
#   root=<dir that relative paths start from; default: the checkout the call runs in>
#   write=<paths or globs the role may write, space-separated>     deny=<paths it may not>
# A missing or unreadable config, an unknown role, or an unreadable tool call is denied.
# Install it as a PreToolUse command hook with an empty matcher. A worker's settings name its own
# --config; the dispatcher and the aide share the project's settings, so each session is launched
# with DISPATCH_ROLE set and the hook finds <state>/guard/<role>.conf.
# Denied:  dispatcher  built-in subagent delegation; a comment carrying an "ACCEPT " verdict line;
#                      a file write outside write=
#          worker      gh pr merge; a force-push; a rebase; an "ACCEPT " verdict line; a file write
#                      outside write= or inside deny=
#          aide        gh pr merge; a file write outside write=
# --probe feeds one forbidden act for <role> through each role-guard hook found in the session's
# settings (default: .claude/settings.local.json, then .claude/settings.json) and exits 0 only if
# one of them denied it as that role; 1 when none is installed, or it allowed the act.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"
role='?'
deny() { echo "role-guard[$role]: denied: $*" >&2; exit 2; }
command -v jq >/dev/null || deny "jq is required to read the tool call"

if [ "${1:-}" = --probe ]; then
  role=${2:-}; settings=
  [ "${3:-}" != --settings ] || settings=${4:-}
  case $role in
    dispatcher) act='{"tool_name":"Task","tool_input":{"prompt":"probe"}}'; tool=Task ;;
    worker|aide) act='{"tool_name":"Bash","tool_input":{"command":"gh pr merge 0"}}'; tool=Bash ;;
    *) echo "usage: role-guard.sh --probe <dispatcher|aide|worker> [--settings <file>]" >&2
      exit 1 ;;
  esac
  found=0
  set -- .claude/settings.local.json .claude/settings.json
  [ -z "$settings" ] || set -- "$settings"
  for f; do
    [ -f "$f" ] || continue
    while IFS= read -r hook; do
      [ -n "$hook" ] || continue
      found=1
      out=$(printf '%s' "$act" | jq -c --arg d "$PWD" '.cwd = $d' |
        CLAUDE_PROJECT_DIR=${CLAUDE_PROJECT_DIR:-$PWD} sh -c "$hook" 2>&1 >/dev/null); rc=$?
      if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF "role-guard[$role]: denied"; then
        echo "probe: the installed hook denied a forbidden act for $role ($f)"; exit 0
      fi
      echo "probe: a hook in $f did not deny as $role (exit $rc): $out" >&2
    done < <(jq -r --arg t "$tool" '.hooks.PreToolUse[]? | (.matcher // "") as $m
      | select($m == "" or $m == "*" or ($t | test("^(" + $m + ")$")))
      | .hooks[]? | select(.type == "command") | .command | select(test("role-guard"))' "$f" \
      2>/dev/null)
  done
  [ "$found" -eq 1 ] || echo "probe: no role-guard hook is installed for $tool calls here" >&2
  exit 1
fi

# The hook. Everything it cannot read is a denial, never an allowance.
conf=${DISPATCH_GUARD_CONFIG:-}
[ "${1:-}" != --config ] || conf=${2:-}
input=$(cat)
st=
if [ -z "$conf" ]; then
  case ${DISPATCH_ROLE:-} in
    ''|*[!a-z]*) deny "no guard config: pass --config, or set DISPATCH_GUARD_CONFIG or" \
      "DISPATCH_ROLE" ;;
  esac
  st=$(ds_state 2>/dev/null) || deny "no project state dir to read the guard config from"
  conf="$st/guard/$DISPATCH_ROLE.conf"
fi
[ -r "$conf" ] || deny "guard config $conf is missing or unreadable"
root=; write=; nowrite=
while IFS='=' read -r k v || [ -n "$k" ]; do
  case $k in role) role=$v ;; root) root=$v ;; write) write=$v ;; deny) nowrite=$v ;; esac
done < "$conf"
case $role in
  dispatcher|aide|worker) ;;
  *) r=$role; role='?'; deny "unknown role '$r' in $conf" ;;
esac
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)
[ -n "$tool" ] || deny "the tool call could not be read"
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty'); [ -d "$cwd" ] || cwd=$PWD

canon() {  # an absolute path with its existing part resolved, so one place has one spelling
  local d=$1 rest=
  while [ ! -d "$d" ] && [ "$d" != / ]; do rest="/${d##*/}$rest"; d=${d%/*}; d=${d:-/}; done
  d=$(cd "$d" && pwd -P); printf '%s\n' "${d%/}$rest"
}
[ -n "$root" ] || root=$(cd "$cwd" && git rev-parse --show-toplevel 2>/dev/null) || root=$cwd
root=$(canon "$root")
listed() {  # path list — is the path (absolute, canonical) under one of the listed entries?
  local p=$1 g
  set -f
  for g in $2; do
    g=${g%/}; case $g in /*) ;; *) g="$root/$g" ;; esac
    # shellcheck disable=SC2254  # entries are glob patterns on purpose
    case $p in $g|$g/*) set +f; return 0 ;; esac
  done
  set +f; return 1
}
check_write() {  # path as the tool named it
  local p=$1
  [ -n "$p" ] || deny "a file write with no path"
  case $p in /*) ;; *) p="$cwd/$p" ;; esac
  case $p/ in */../*) deny "a write to a path with '..' in it: $1" ;; esac
  p=$(canon "$p")
  ! listed "$p" "$nowrite" || deny "$1 is on this role's no-write list"
  listed "$p" "$write" || deny "$1 is outside the paths this $role may write"
}
accept_line() { grep -q '^ACCEPT ' 2>/dev/null; }  # the verdict line, as watch.sh reads it
check_command() {  # the shell command's text
  local cmd=$1 seg sub flat has_gh=0 body=0 t f
  while IFS= read -r seg; do
    set -f; set -- $seg; set +f
    while [ $# -gt 0 ]; do case ${1##*/} in gh|git) break ;; esac; shift; done
    [ $# -gt 0 ] || continue
    if [ "${1##*/}" = gh ]; then
      has_gh=1; flat=" $* "
      case $role:$flat in
        dispatcher:*) ;;
        *" pr merge "*|*pulls/*/merge*) deny "gh pr merge: landing is the dispatcher's" ;;
      esac
      continue
    fi
    [ "$role" = worker ] || continue
    shift; sub=
    while [ $# -gt 0 ]; do
      case $1 in -C|-c) shift ;; -*) ;; *) sub=$1; shift; break ;; esac
      [ $# -eq 0 ] || shift
    done
    for t; do
      case $sub:$t in
        push:--force*|push:-f|push:-[!-]*f*|push:+*) deny "a force-push: merge the base instead" ;;
        pull:--rebase=false) ;;
        pull:--rebase*|pull:-r|pull:-[!-]*r*) deny "a rebase: merge the base instead" ;;
      esac
    done
    [ "$sub" != rebase ] || deny "a rebase: merge the base into the branch instead"
  done < <(printf '%s\n' "$cmd" | tr -d "\"'" | tr ';|&()`' '\n\n\n\n\n\n')
  [ "$has_gh" -eq 1 ] && [ "$role" != aide ] || return 0
  printf '%s\n' "$cmd" | sed 's/\\n/\
/g' | tr "\"'" '\n\n' | accept_line && deny "an ACCEPT verdict line: verdicts are the aide's"
  set -f; set -- $(printf '%s' "$cmd" | tr -d "\"'"); set +f
  for t; do  # a comment body read from a file
    f=
    [ "$body" -eq 0 ] || f=$t
    case $t in --body-file=*) f=${t#*=} ;; *=@*) f=${t#*=@} ;; esac
    case $t in --body-file|-F|--input) body=1 ;; *) body=0 ;; esac
    [ -n "$f" ] && [ "$f" != - ] || continue
    case $f in /*) ;; *) f="$cwd/$f" ;; esac
    [ ! -f "$f" ] || ! accept_line < "$f" ||
      deny "an ACCEPT verdict line in $t: verdicts are the aide's"
  done
}

q() { printf '%s' "$input" | jq -r "$1" 2>/dev/null; }
case $tool in
  Task|Agent|Workflow)
    [ "$role" != dispatcher ] ||
      deny "built-in delegation ($tool) escapes the watcher and the records: start a worker" ;;
  Bash|shell|local_shell|exec_command)
    check_command "$(q '.tool_input.command | if type == "array" then join(" ") else . end
      // ""')" ;;
  Write|Edit|MultiEdit|NotebookEdit)
    check_write "$(q '.tool_input | .file_path // .notebook_path // .path // empty')" ;;
  apply_patch)
    while IFS= read -r p; do check_write "$p"; done < <(
      q '.tool_input | .patch // .input // empty' |
        sed -nE 's/^\*\*\* (Add|Update|Delete) File: //p; s/^\*\*\* Move to: //p') ;;
esac
exit 0
