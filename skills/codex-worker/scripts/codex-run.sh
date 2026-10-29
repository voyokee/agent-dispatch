#!/usr/bin/env bash
# codex-run.sh — run OpenAI Codex CLI as an implementation worker and record
# exactly what it changed, so Claude can review evidence instead of claims.
#
# Usage:
#   codex-run.sh start  <repo_dir> <task_file>
#   codex-run.sh resume <repo_dir> <session_id> <feedback_file>
#
# Env (optional):
#   CODEX_WORKER_MODEL=<model>   pass -m to codex
#   CODEX_WORKER_NETWORK=1       allow network inside the workspace-write sandbox
#
# Output: a run directory (printed at the end) holding prompt.md, events.jsonl,
# stderr.log, last-message.md, commands.tsv, changed-files.txt, summary.txt.
set -uo pipefail

die() { echo "codex-run: $*" >&2; exit 2; }

command -v codex >/dev/null || die "codex CLI not found on PATH"
command -v jq >/dev/null || die "jq is required"

mode=${1:-}
repo=${2:-}
[[ $mode == start && $# -eq 3 ]] || [[ $mode == resume && $# -eq 4 ]] ||
  die "usage: codex-run.sh start <repo_dir> <task_file> | resume <repo_dir> <session_id> <feedback_file>"

repo=$(cd "$repo" 2>/dev/null && pwd) || die "no such directory: $2"
git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$repo is not inside a git work tree"
root=$(git -C "$repo" rev-parse --show-toplevel)

# Every path that differs from HEAD (or is untracked), with its content hash.
snapshot() {
  local paths
  if git -C "$root" rev-parse --verify -q HEAD >/dev/null; then
    paths=$( { git -C "$root" diff --name-only HEAD; git -C "$root" ls-files -o --exclude-standard; } | sort -u )
  else
    paths=$(git -C "$root" ls-files -co --exclude-standard | sort -u)
  fi
  [[ -z $paths ]] && return 0
  while IFS= read -r p; do
    if [[ -f $root/$p ]]; then
      printf '%s\t%s\n' "$p" "$(git -C "$root" hash-object -- "$p")"
    else
      printf '%s\tDELETED\n' "$p"
    fi
  done <<<"$paths"
}

run_dir="${TMPDIR:-/tmp}/codex-worker/$(basename "$root")-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$run_dir"

common=(--json -o "$run_dir/last-message.md" -c 'approval_policy="never"')
[[ -n ${CODEX_WORKER_MODEL:-} ]] && common+=(-m "$CODEX_WORKER_MODEL")
[[ ${CODEX_WORKER_NETWORK:-} == 1 ]] && common+=(-c 'sandbox_workspace_write.network_access=true')

if [[ $mode == start ]]; then
  [[ -f $3 ]] || die "task file not found: $3"
  cp "$3" "$run_dir/prompt.md"
  cmd=(codex exec "${common[@]}" -s workspace-write -C "$repo" -)
else
  [[ -f $4 ]] || die "feedback file not found: $4"
  cp "$4" "$run_dir/prompt.md"
  # `exec resume` has no -s/-C: set the sandbox via config and run from the repo.
  cmd=(codex exec resume "${common[@]}" -c 'sandbox_mode="workspace-write"' "$3" -)
fi

pre_head=$(git -C "$root" rev-parse -q --verify HEAD || echo none)
snapshot | sort >"$run_dir/pre-status.tsv"

started=$(date +%s)
(cd "$repo" && "${cmd[@]}" <"$run_dir/prompt.md" >"$run_dir/events.jsonl" 2>"$run_dir/stderr.log")
codex_exit=$?
elapsed=$(($(date +%s) - started))

post_head=$(git -C "$root" rev-parse -q --verify HEAD || echo none)
snapshot | sort >"$run_dir/post-status.tsv"

# A path changed during the run if its (path, hash) line exists in only one snapshot.
sort "$run_dir/pre-status.tsv" "$run_dir/post-status.tsv" | uniq -u | cut -f1 | sort -u >"$run_dir/changed-files.txt"
session_id=$(jq -r 'select(.type=="thread.started") | .thread_id' "$run_dir/events.jsonl" 2>/dev/null | head -1)
[[ -z $session_id && $mode == resume ]] && session_id=$3

# The user's own uncommitted changes are the dirty state before the session's
# first run; keep it so repair rounds don't flag Codex's earlier edits.
baseline="${TMPDIR:-/tmp}/codex-worker/baseline-${session_id:-none}.tsv"
[[ $mode == start && -n $session_id ]] && cp "$run_dir/pre-status.tsv" "$baseline"
[[ -f $baseline ]] || baseline="$run_dir/pre-status.tsv"
cut -f1 "$baseline" | sort -u | comm -12 - "$run_dir/changed-files.txt" >"$run_dir/overlap.txt"
jq -r 'select(.type=="item.completed" and .item.type=="command_execution")
       | "\(.item.exit_code)\t\(.item.command)"' "$run_dir/events.jsonl" >"$run_dir/commands.tsv" 2>/dev/null
failed=$(jq -r 'select(.type=="turn.failed" or .type=="error") | (.error.message // .message // "error")' \
  "$run_dir/events.jsonl" 2>/dev/null | head -3)
usage=$(jq -c 'select(.type=="turn.completed") | .usage' "$run_dir/events.jsonl" 2>/dev/null | tail -1)

{
  echo "== codex-worker run =="
  echo "mode:        $mode"
  echo "repo:        $repo"
  echo "run_dir:     $run_dir"
  echo "session_id:  ${session_id:-unknown}"
  echo "codex_exit:  $codex_exit  (elapsed ${elapsed}s)"
  [[ -n $failed ]] && echo "codex_error: $failed"
  [[ -n $usage ]] && echo "usage:       $usage"
  if [[ $pre_head != "$post_head" ]]; then
    echo "WARNING: HEAD moved during the run ($pre_head -> $post_head). Codex created commits; inspect with git log."
  fi
  echo
  echo "Files changed during this run ($(wc -l <"$run_dir/changed-files.txt" | tr -d ' ')):"
  sed 's/^/  /' "$run_dir/changed-files.txt"
  if [[ -s $run_dir/overlap.txt ]]; then
    echo
    echo "WARNING: these files had uncommitted user changes before Codex started and were touched in this run:"
    sed 's/^/  /' "$run_dir/overlap.txt"
  fi
  echo
  echo "Commands Codex ran: $(wc -l <"$run_dir/commands.tsv" | tr -d ' ') (non-zero exits: $(awk -F'\t' '$1!="0"' "$run_dir/commands.tsv" | wc -l | tr -d ' ')) -> $run_dir/commands.tsv"
  echo "Codex final report: $run_dir/last-message.md"
} | tee "$run_dir/summary.txt"

exit "$codex_exit"
