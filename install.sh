#!/usr/bin/env bash
# Install the codex-worker skill into ~/.claude/skills.
# Usage: ./install.sh [--force]
set -euo pipefail

src="$(cd "$(dirname "$0")" && pwd)/skills/codex-worker"
dest="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/codex-worker"

if [[ -e $dest && ${1:-} != --force ]]; then
  echo "$dest already exists. Re-run with --force to replace it." >&2
  exit 1
fi

mkdir -p "$(dirname "$dest")"
rm -rf "$dest"
cp -R "$src" "$dest"
chmod +x "$dest/scripts/codex-run.sh"
echo "Installed codex-worker to $dest"

for tool in codex jq git; do
  command -v "$tool" >/dev/null || echo "warning: '$tool' not found on PATH (required)" >&2
done

echo
echo "Optional: add the rules in examples/CLAUDE.md to ~/.claude/CLAUDE.md so Codex stays opt-in."
echo "Start a new Claude Code session to load the skill."
