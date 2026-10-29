#!/usr/bin/env bash
# codex-run.sh — run OpenAI Codex CLI as an implementation worker and record
# exactly what it changed, so Claude can review evidence instead of claims.
#
# Usage:
#   codex-run.sh [options] start  <repo_dir> <task_file>
#   codex-run.sh [options] resume <repo_dir> <session_id> <feedback_file>
#   codex-run.sh models
#
# Options:
#   -m, --model <model>    Codex model (default: CODEX_WORKER_MODEL, else ~/.codex/config.toml)
#   -e, --effort <level>   reasoning effort, e.g. low|medium|high|xhigh|max
#                          (default: CODEX_WORKER_EFFORT, else config)
#   A resume reuses the model and effort of the session's first run unless overridden.
#
# Env (optional):
#   CODEX_WORKER_NETWORK=1   allow network inside the workspace-write sandbox
#
# Output: a run directory (printed at the end) holding prompt.md, events.jsonl,
# stderr.log, last-message.md, commands.tsv, changed-files.txt, summary.txt.
set -uo pipefail

die() { echo "codex-run: $*" >&2; exit 2; }

command -v codex >/dev/null || die "codex CLI not found on PATH"
command -v jq >/dev/null || die "jq is required"

codex_home=${CODEX_HOME:-$HOME/.codex}
models_cache="$codex_home/models_cache.json"
state_dir="${TMPDIR:-/tmp}/codex-worker"

# Value of a top-level key in config.toml (before the first [table]).
config_value() {
  [[ -f $codex_home/config.toml ]] || return 0
  awk -v k="$1" '/^\[/{exit} $0 ~ "^"k"[[:space:]]*=" {sub(/^[^=]*=[[:space:]]*/, ""); gsub(/"/, ""); print; exit}' \
    "$codex_home/config.toml"
}

list_models() {
  echo "config default: model=$(config_value model) effort=$(config_value model_reasoning_effort)"
  [[ -f $models_cache ]] || { echo "(no model cache at $models_cache; run codex once to populate it)"; return 0; }
  echo
  jq -r '.models[] | select(.visibility != "hide")
         | "\(.slug)\t\(.display_name)\tdefault effort: \(.default_reasoning_level)\tefforts: \([.supported_reasoning_levels[]?.effort] | join(","))"' \
    "$models_cache" | column -t -s $'\t'
}

model=${CODEX_WORKER_MODEL:-}
effort=${CODEX_WORKER_EFFORT:-}
model_set=0
effort_set=0
[[ -n $model ]] && model_set=1
[[ -n $effort ]] && effort_set=1
while [[ $# -gt 0 ]]; do
  case $1 in
    -m|--model) [[ $# -ge 2 ]] || die "$1 needs a value"; model=$2; model_set=1; shift 2 ;;
    -e|--effort) [[ $# -ge 2 ]] || die "$1 needs a value"; effort=$2; effort_set=1; shift 2 ;;
    --) shift; break ;;
    -*) die "unknown option: $1" ;;
    *) break ;;
  esac
done

mode=${1:-}
if [[ $mode == models ]]; then
  list_models
  exit 0
fi

repo=${2:-}
[[ $mode == start && $# -eq 3 ]] || [[ $mode == resume && $# -eq 4 ]] ||
  die "usage: codex-run.sh [-m model] [-e effort] start <repo_dir> <task_file> | resume <repo_dir> <session_id> <feedback_file> | models"

repo=$(cd "$repo" 2>/dev/null && pwd) || die "no such directory: $2"
git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$repo is not inside a git work tree"
root=$(git -C "$repo" rev-parse --show-toplevel)

# A resume keeps the session's original model/effort unless overridden.
if [[ $mode == resume && -f $state_dir/model-$3.env ]]; then
  # shellcheck disable=SC1090
  saved_model= saved_effort=; source "$state_dir/model-$3.env"
  [[ $model_set == 0 ]] && model=$saved_model
  [[ $effort_set == 0 ]] && effort=$saved_effort
fi

# Check the choice against Codex's model cache; warn only, the cache can be stale.
if [[ -f $models_cache ]]; then
  check_model=${model:-$(config_value model)}
  if [[ -n $model ]] && ! jq -e --arg m "$model" '.models[] | select(.slug == $m)' "$models_cache" >/dev/null; then
    echo "codex-run: warning: model '$model' is not in $models_cache (see: codex-run.sh models)" >&2
  elif [[ -n $effort && -n $check_model ]] &&
    ! jq -e --arg m "$check_model" --arg e "$effort" \
      '.models[] | select(.slug == $m) | .supported_reasoning_levels[]? | select(.effort == $e)' "$models_cache" >/dev/null; then
    echo "codex-run: warning: effort '$effort' is not listed for model '$check_model'" >&2
  fi
fi

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

run_dir="$state_dir/$(basename "$root")-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$run_dir"

common=(--json -o "$run_dir/last-message.md" -c 'approval_policy="never"')
[[ -n $model ]] && common+=(-m "$model")
[[ -n $effort ]] && common+=(-c "model_reasoning_effort=\"$effort\"")
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
baseline="$state_dir/baseline-${session_id:-none}.tsv"
[[ $mode == start && -n $session_id ]] && cp "$run_dir/pre-status.tsv" "$baseline"
[[ -f $baseline ]] || baseline="$run_dir/pre-status.tsv"
cut -f1 "$baseline" | sort -u | comm -12 - "$run_dir/changed-files.txt" >"$run_dir/overlap.txt"

if [[ $mode == start && -n $session_id ]]; then
  printf 'saved_model=%q\nsaved_effort=%q\n' "$model" "$effort" >"$state_dir/model-$session_id.env"
fi

jq -r 'select(.type=="item.completed" and .item.type=="command_execution")
       | "\(.item.exit_code)\t\(.item.command)"' "$run_dir/events.jsonl" >"$run_dir/commands.tsv" 2>/dev/null
failed=$(jq -r 'select(.type=="turn.failed" or .type=="error") | (.error.message // .message // "error")' \
  "$run_dir/events.jsonl" 2>/dev/null | head -3)
usage=$(jq -c 'select(.type=="turn.completed") | .usage' "$run_dir/events.jsonl" 2>/dev/null | tail -1)

{
  echo "== codex-worker run =="
  echo "mode:        $mode"
  echo "repo:        $repo"
  echo "model:       ${model:-$(config_value model) (config default)}"
  echo "effort:      ${effort:-$(config_value model_reasoning_effort) (config default)}"
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
