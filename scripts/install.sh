#!/usr/bin/env bash
# install.sh — link every skill into the agent skill directories (Claude Code and the shared
# ~/.agents/skills used by Codex, Pi, and OpenCode). Refuses to replace anything it did not link.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
targets=("${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}" "${AGENTS_SKILLS_DIR:-$HOME/.agents/skills}")
for dir in "${targets[@]}"; do
  mkdir -p "$dir"
  for src in "$root"/skills/*/; do
    src="${src%/}"; dest="$dir/$(basename "$src")"
    if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
      echo "ok:      $dest"
    elif [ -e "$dest" ] || [ -L "$dest" ]; then
      echo "refused: $dest exists and is not this repo's link" >&2; exit 1
    else
      ln -s "$src" "$dest"; echo "linked:  $dest -> $src"
    fi
  done
done
