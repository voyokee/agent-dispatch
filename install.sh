#!/usr/bin/env bash
# Install the agent-dispatch skill for the agents that will act as Master.
# Usage: ./install.sh [--target claude|agents|all] [--force]
#   claude  ~/.claude/skills/agent-dispatch   (Claude Code; default)
#   agents  ~/.agents/skills/agent-dispatch   (Codex and Cursor)
#   all     both
# The same files are copied to each place; there is only one source.
set -euo pipefail

target=claude
force=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --target) [[ $# -ge 2 ]] || { echo "--target needs a value" >&2; exit 2; }; target=$2; shift 2 ;;
    --force) force=1; shift ;;
    *) echo "usage: ./install.sh [--target claude|agents|all] [--force]" >&2; exit 2 ;;
  esac
done

claude_dest="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/agent-dispatch"
agents_dest="$HOME/.agents/skills/agent-dispatch"
case $target in
  claude) dests=("$claude_dest") ;;
  agents) dests=("$agents_dest") ;;
  all) dests=("$claude_dest" "$agents_dest") ;;
  *) echo "unknown target '$target' (use claude, agents or all)" >&2; exit 2 ;;
esac

src="$(cd "$(dirname "$0")" && pwd)/skills/agent-dispatch"

for dest in "${dests[@]}"; do
  if [[ -e $dest && $force != 1 ]]; then
    echo "$dest already exists. Re-run with --force to replace it." >&2
    exit 1
  fi
done

for dest in "${dests[@]}"; do
  mkdir -p "$(dirname "$dest")"
  rm -rf "$dest"
  cp -R "$src" "$dest"
  chmod +x "$dest/scripts/worker-run.sh" "$dest/scripts/dispatchctl.sh"
  echo "Installed agent-dispatch to $dest"
done

for tool in jq git; do
  command -v "$tool" >/dev/null || echo "warning: '$tool' not found on PATH (required)" >&2
done
# Workers are optional; warn about each one that is missing.
command -v codex >/dev/null || echo "note: 'codex' not found; the codex worker is unavailable" >&2
command -v claude >/dev/null || echo "note: 'claude' not found; the claude worker is unavailable" >&2
command -v agent >/dev/null || command -v cursor-agent >/dev/null || [[ -f $HOME/AppData/Local/cursor-agent/agent.cmd ]] ||
  echo "note: Cursor agent CLI ('agent') not found; the cursor worker is unavailable" >&2

echo
echo "Optional: keep external workers opt-in with the rules in examples/CLAUDE.md (Claude Code, ~/.claude/CLAUDE.md)"
echo "or examples/AGENTS.md (Codex ~/.codex/AGENTS.md, Cursor user rules)."
echo "Start a new agent session to load the skill."
