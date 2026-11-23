# runtime.sh — the one place that knows the terminals (tmux, herdr) and the agents (Claude Code,
# Codex). Sourced by start.sh and inbox.sh, never run. Bash 3.2-safe.
# Env: DISPATCH_TERM (tmux|herdr; default: herdr inside herdr, else tmux), DISPATCH_TMUX (tmux),
#      DISPATCH_HERDR (herdr), DISPATCH_AGENT_BIN (the agent's binary, default its own name).

rt_sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }  # one shell-quoted word

rt_term() {  # print the terminal that carries workers here
  case ${DISPATCH_TERM:-} in
    tmux|herdr) echo "$DISPATCH_TERM" ;;
    '') if [ "${HERDR_ENV:-}" = 1 ]; then echo herdr; else echo tmux; fi ;;
    *) echo "dispatch: unknown DISPATCH_TERM '$DISPATCH_TERM'" >&2; return 1 ;;
  esac
}

rt_open() {  # term name dir command — open a terminal running the command; print its handle
  local pane
  case $1 in
    tmux)
      if [ -n "${TMUX:-}" ]; then
        "${DISPATCH_TMUX:-tmux}" new-window -d -P -F '#{pane_id}' -n "$2" -c "$3" "$4"
      else  # no client here: a detached session the user can attach to
        "${DISPATCH_TMUX:-tmux}" new-session -d -P -F '#{pane_id}' -s "dispatch-$2" -c "$3" "$4"
      fi ;;
    herdr)
      pane=$("${DISPATCH_HERDR:-herdr}" pane split --current --direction right --cwd "$3" \
        --no-focus | jq -r '.result.pane.pane_id // empty') && [ -n "$pane" ] || return 1
      "${DISPATCH_HERDR:-herdr}" pane run "$pane" "$4" >/dev/null || return 1
      echo "$pane" ;;
    *) return 1 ;;
  esac
}

rt_alive() {  # term handle — does that terminal still exist?
  case $1 in
    tmux) "${DISPATCH_TMUX:-tmux}" display-message -p -t "$2" '#{pane_id}' >/dev/null 2>&1 ;;
    herdr) "${DISPATCH_HERDR:-herdr}" pane get "$2" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

rt_type() {  # term handle line — type one line into that terminal and submit it
  case $1 in
    tmux) "${DISPATCH_TMUX:-tmux}" send-keys -t "$2" -l -- "$3" &&
      "${DISPATCH_TMUX:-tmux}" send-keys -t "$2" Enter ;;
    herdr) "${DISPATCH_HERDR:-herdr}" pane run "$2" "$3" >/dev/null ;;
    *) return 1 ;;
  esac
}

rt_trust() {  # agent main-root worktree — record the folder as trusted, as the agent's docs say
  local f tmp
  case $1 in
    claude)  # keyed on the repository root; a worktree uses the main checkout's
      f="$HOME/.claude.json"
      [ "$(jq -r --arg p "$2" '.projects[$p].hasTrustDialogAccepted // false' "$f" \
        2>/dev/null)" != true ] || return 0
      [ -f "$f" ] || echo '{}' > "$f"
      tmp=$(mktemp "$f.XXXXXX") &&
        jq --arg p "$2" '.projects[$p].hasTrustDialogAccepted = true' "$f" > "$tmp" &&
        mv "$tmp" "$f" || { rm -f "$tmp"; return 1; } ;;
    codex)
      f="${CODEX_HOME:-$HOME/.codex}/config.toml"
      ! grep -qF "[projects.\"$3\"]" "$f" 2>/dev/null || return 0
      mkdir -p "$(dirname "$f")" &&
        printf '\n[projects."%s"]\ntrust_level = "trusted"\n' "$3" >> "$f" ;;
    *) return 1 ;;
  esac
}

rt_hooks() {  # agent start-script guard-script guard-config — print the agent's hooks as JSON
  local s g
  s=$(rt_sq "$2"); g=$(rt_sq "$3")
  case $1 in
    claude) g="$g --config $(rt_sq "$4")" ;;  # per session, so the config is named outright
    codex) g="[ -z \"\$DISPATCH_GUARD_CONFIG\" ] || $g" ;;  # user-level: inert outside a worker
    *) return 1 ;;
  esac
  jq -n --arg s "$s" --arg g "$g" '
    def h($c): [{hooks: [{type: "command", command: $c}]}];
    {hooks: {UserPromptSubmit: h($s + " --hook busy"), Stop: h($s + " --hook idle"),
      SessionEnd: h($s + " --hook ended"), PreToolUse: h($g)}}'
}

rt_agent() {  # agent settings-file prompt — print the command that starts a worker session.
  # Never a permission-bypass flag: the worker runs in the mode the user configured.
  case $1 in
    claude) echo "${DISPATCH_AGENT_BIN:-claude} --settings $(rt_sq "$2") $(rt_sq "$3")" ;;
    codex) echo "${DISPATCH_AGENT_BIN:-codex} $(rt_sq "$3")" ;;  # its hooks are user-level
    *) return 1 ;;
  esac
}
