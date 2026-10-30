#!/usr/bin/env bash
# worker-run.sh — run an external coding CLI as an implementation worker and
# record exactly what it changed, so the Master (the agent session that called
# it: Claude Code, Codex or Cursor) can review evidence instead of claims.
#
# Workers:
#   codex   OpenAI Codex CLI   (codex exec, workspace-write sandbox)
#   claude  Claude Code CLI    (claude -p, acceptEdits, tool allowlist, git writes denied)
#   cursor  Cursor agent CLI   (agent -p; sandbox enabled on macOS/Linux, none on Windows)
#
# Usage:
#   worker-run.sh [options] start  <repo_dir> <task_file>
#   worker-run.sh [options] resume <repo_dir> <session_id> <feedback_file>
#   worker-run.sh [options] models
#
# Options:
#   -w, --worker <name>    codex | claude | cursor (default: codex)
#   -m, --model <model>    model (default: <WORKER>_WORKER_MODEL, else the CLI's own default)
#   -e, --effort <level>   reasoning effort (default: <WORKER>_WORKER_EFFORT, else the CLI's default)
#                          cursor has no effort flag: -m gpt-5.6-sol -e high runs gpt-5.6-sol-high
#                          (looked up in `agent models`; else passed as model[effort=high]).
#   A resume reuses the worker, model and effort of the session's first run unless overridden.
#
# Env (optional):
#   CODEX_WORKER_NETWORK=1      codex: allow network inside the workspace-write sandbox
#   CLAUDE_WORKER_TOOLS="..."   claude: tools to allow (default: "Read Edit Write Glob Grep Bash")
#   CURSOR_WORKER_FORCE=1       cursor: allow shell commands (--force)
#   AGENT_DISPATCH_STATE=<dir>  where session state lives (default: $XDG_STATE_HOME/agent-dispatch,
#                               else ~/.local/state/agent-dispatch)
#
# Output: a run directory under $TMPDIR/agent-dispatch (printed at the end) holding
# prompt.md, events.jsonl, stderr.log, last-message.md, commands.tsv, changed-files.txt,
# commits.txt, summary.txt and summary.json.
#
# Only one worker runs per work tree at a time (lock: <git dir>/agent-dispatch.lock).
# The worker runs with AGENT_DISPATCH_WORKER=1, and this script refuses to start under it.
#
# Exit status: the worker's own exit code; 2 for usage/setup errors; 3 if the work
# tree is locked by another running worker.
set -uo pipefail

die() { echo "worker-run: $*" >&2; exit 2; }

usage() {
  die "usage: worker-run.sh [-w codex|claude|cursor] [-m model] [-e effort] start <repo_dir> <task_file> | resume <repo_dir> <session_id> <feedback_file> | models"
}

# Session state (worker/model per session, the user's pre-existing changes) must
# outlive temp cleanup, so it lives in the user's state dir; per-run evidence stays in temp.
state_dir="${AGENT_DISPATCH_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-dispatch}"
runs_dir="${TMPDIR:-/tmp}/agent-dispatch"
codex_home=${CODEX_HOME:-$HOME/.codex}
models_cache="$codex_home/models_cache.json"
read -r -a claude_tools <<<"${CLAUDE_WORKER_TOOLS:-Read Edit Write Glob Grep Bash}"
# Git writes a worker must never run: the repo owner commits, merges and pushes.
claude_denied=("Bash(git commit *)" "Bash(git push *)" "Bash(git merge *)" "Bash(git rebase *)"
  "Bash(git reset *)" "Bash(git checkout *)" "Bash(git stash *)" "Bash(git clean *)" "Bash(git restore *)")

# Value of a top-level key in config.toml (before the first [table]).
config_value() {
  [[ -f $codex_home/config.toml ]] || return 0
  awk -v k="$1" '/^\[/{exit} $0 ~ "^"k"[[:space:]]*=" {sub(/^[^=]*=[[:space:]]*/, ""); gsub(/"/, ""); print; exit}' \
    "$codex_home/config.toml"
}

list_models() {
  case $worker in
    codex)
      echo "config default: model=$(config_value model) effort=$(config_value model_reasoning_effort)"
      [[ -f $models_cache ]] || { echo "(no model cache at $models_cache; run codex once to populate it)"; return 0; }
      echo
      jq -r '.models[] | select(.visibility != "hide")
             | "\(.slug)\t\(.display_name)\tdefault effort: \(.default_reasoning_level)\tefforts: \([.supported_reasoning_levels[]?.effort] | join(","))"' \
        "$models_cache" | column -t -s $'\t'
      ;;
    claude)
      echo "aliases and model IDs (any other ID is passed to claude unchanged):"
      cat <<'EOF'
opus
sonnet
haiku
claude-fable-5-1
claude-opus-5-5
claude-sonnet-5-5
claude-haiku-5-5

efforts: low, medium, high, xhigh, max (CLI default when omitted)
EOF
      ;;
    cursor) "$cursor_cli" models ;;
  esac
}

worker=codex
model=
effort=
worker_set=0
model_set=0
effort_set=0
while [[ $# -gt 0 ]]; do
  case $1 in
    -w|--worker) [[ $# -ge 2 ]] || die "$1 needs a value"; worker=$2; worker_set=1; shift 2 ;;
    -m|--model) [[ $# -ge 2 ]] || die "$1 needs a value"; model=$2; model_set=1; shift 2 ;;
    -e|--effort) [[ $# -ge 2 ]] || die "$1 needs a value"; effort=$2; effort_set=1; shift 2 ;;
    --) shift; break ;;
    -*) die "unknown option: $1" ;;
    *) break ;;
  esac
done

mode=${1:-}
case $mode in
  models) [[ $# -eq 1 ]] || usage ;;
  start) [[ $# -eq 3 ]] || usage ;;
  resume) [[ $# -eq 4 ]] || usage ;;
  *) usage ;;
esac

# Workers must not dispatch further workers.
if [[ $mode != models && ${AGENT_DISPATCH_WORKER:-} == 1 ]]; then
  die "refusing to dispatch: this process is itself running as an agent-dispatch worker"
fi

# A resume keeps the session's original worker, model and effort unless overridden.
have_saved=0
if [[ $mode == resume && -f $state_dir/session-$3.env ]]; then
  saved_worker= saved_model= saved_effort=
  # shellcheck disable=SC1090
  source "$state_dir/session-$3.env"
  have_saved=1
  [[ $worker_set == 0 && -n $saved_worker ]] && worker=$saved_worker
  [[ $model_set == 0 ]] && model=$saved_model
  [[ $effort_set == 0 ]] && effort=$saved_effort
fi

case $worker in
  codex|claude|cursor) ;;
  *) die "unknown worker '$worker' (use codex, claude or cursor)" ;;
esac

# Environment defaults, e.g. CLAUDE_WORKER_MODEL / CLAUDE_WORKER_EFFORT.
upper=$(printf '%s' "$worker" | tr '[:lower:]' '[:upper:]')  # not ${worker^^}: macOS ships bash 3.2
if [[ $have_saved == 0 ]]; then
  env_model="${upper}_WORKER_MODEL" env_effort="${upper}_WORKER_EFFORT"
  [[ $model_set == 0 && -n ${!env_model:-} ]] && model=${!env_model}
  [[ $effort_set == 0 && -n ${!env_effort:-} ]] && effort=${!env_effort}
fi

command -v jq >/dev/null || die "jq is required"
cursor_cli=
case $worker in
  codex) command -v codex >/dev/null || die "codex CLI not found on PATH" ;;
  claude) command -v claude >/dev/null || die "claude CLI not found on PATH" ;;
  cursor)
    cursor_cli=$(command -v agent || command -v cursor-agent || true)
    # Windows installs agent.cmd under %LOCALAPPDATA%, which Git Bash may not have on PATH.
    [[ -z $cursor_cli && -f $HOME/AppData/Local/cursor-agent/agent.cmd ]] &&
      cursor_cli=$HOME/AppData/Local/cursor-agent/agent.cmd
    [[ -n $cursor_cli ]] || die "Cursor agent CLI not found (looked for 'agent', 'cursor-agent' and %LOCALAPPDATA%\\cursor-agent)"
    ;;
esac

if [[ $mode == models ]]; then
  list_models
  exit 0
fi

case $worker in
  claude)
    [[ -z $effort || $effort =~ ^(low|medium|high|xhigh|max)$ ]] ||
      die "claude effort must be low, medium, high, xhigh or max (got '$effort')"
    ;;
  cursor)
    if [[ -n $effort ]]; then
      [[ -n $model ]] || die "cursor: the effort is part of the model, so pass -m <model> with -e"
      [[ $model != *\[* ]] || die "cursor: model '$model' already has bracket parameters; drop -e or the brackets"
      # Most Cursor models bake the effort into the ID (gpt-5.6-sol + high -> gpt-5.6-sol-high;
      # some list it as extra-high instead of xhigh). Parameterized models take [effort=...].
      listed=$("$cursor_cli" models 2>/dev/null | awk '{print $1}')
      resolved=
      for cand in "$model-$effort" "$model-${effort/xhigh/extra-high}"; do
        if grep -Fx -- "$cand" <<<"$listed" >/dev/null; then resolved=$cand; break; fi
      done
      if [[ -z $resolved ]]; then
        echo "worker-run: note: no '$model-$effort' in 'agent models'; passing $model[effort=$effort]" >&2
        resolved="$model[effort=$effort]"
      fi
      model=$resolved
      effort=
    fi
    ;;
esac

repo_arg=$2
repo=$(cd "$repo_arg" 2>/dev/null && pwd) || die "no such directory: $repo_arg"
git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$repo is not inside a git work tree"
root=$(git -C "$repo" rev-parse --show-toplevel)

if [[ $mode == start ]]; then
  [[ -f $3 ]] || die "task file not found: $3"
  input=$3
else
  sid=$3
  [[ -f $4 ]] || die "feedback file not found: $4"
  input=$4
fi

# Codex's model cache: warn only, the cache can be stale.
if [[ $worker == codex && -f $models_cache ]]; then
  check_model=${model:-$(config_value model)}
  if [[ -n $model ]] && ! jq -e --arg m "$model" '.models[] | select(.slug == $m)' "$models_cache" >/dev/null; then
    echo "worker-run: warning: model '$model' is not in $models_cache (see: worker-run.sh -w codex models)" >&2
  elif [[ -n $effort && -n $check_model ]] &&
    ! jq -e --arg m "$check_model" --arg e "$effort" \
      '.models[] | select(.slug == $m) | .supported_reasoning_levels[]? | select(.effort == $e)' "$models_cache" >/dev/null; then
    echo "worker-run: warning: effort '$effort' is not listed for model '$check_model'" >&2
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

# One writer per work tree: an atomic mkdir lock in the git dir. A lock whose
# owner process is gone (same host) is reclaimed; a live or unknown one is not.
lock="$(git -C "$root" rev-parse --absolute-git-dir)/agent-dispatch.lock"
host=$(hostname 2>/dev/null || echo unknown)
winpid=$(cat /proc/$$/winpid 2>/dev/null || true)

acquire_lock() {
  mkdir "$lock" 2>/dev/null || return 1
  printf 'pid=%s\nwinpid=%s\nhost=%s\nworker=%s\nmode=%s\nstarted=%s\n' \
    "$$" "$winpid" "$host" "$worker" "$mode" "$(date '+%Y-%m-%d %H:%M:%S')" >"$lock/owner"
}

# Git Bash and Cygwin keep separate PID tables, so on Windows also ask tasklist
# about the native PID before calling an owner dead.
owner_alive() {
  local pid=$1 wpid=$2
  kill -0 "$pid" 2>/dev/null && return 0
  [[ -n $wpid ]] && command -v tasklist >/dev/null &&
    MSYS2_ARG_CONV_EXCL='*' tasklist /NH /FI "PID eq $wpid" 2>/dev/null | grep -qw -- "$wpid"
}

if ! acquire_lock; then
  owner_pid=$(sed -n 's/^pid=//p' "$lock/owner" 2>/dev/null)
  owner_winpid=$(sed -n 's/^winpid=//p' "$lock/owner" 2>/dev/null)
  owner_host=$(sed -n 's/^host=//p' "$lock/owner" 2>/dev/null)
  if [[ -n $owner_pid && $owner_host == "$host" ]] && ! owner_alive "$owner_pid" "$owner_winpid"; then
    echo "worker-run: reclaiming stale lock of dead process $owner_pid ($lock)" >&2
    rm -rf "$lock"
    acquire_lock || { echo "worker-run: $root was locked again while reclaiming; try later" >&2; exit 3; }
  else
    {
      echo "worker-run: $root is busy: another agent-dispatch worker holds $lock"
      sed 's/^/  /' "$lock/owner" 2>/dev/null
      echo "If you are sure no worker is running there, remove the lock directory and retry."
    } >&2
    exit 3
  fi
fi
trap 'rm -rf "$lock"' EXIT
trap 'exit 130' INT TERM

mkdir -p "$state_dir" "$runs_dir"
run_dir="$runs_dir/$(basename "$root")-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$run_dir"
prompt="$run_dir/prompt.md"
cp "$input" "$prompt"
events="$run_dir/events.jsonl"

case $worker in
  codex)
    common=(--json -o "$run_dir/last-message.md" -c 'approval_policy="never"')
    [[ -n $model ]] && common+=(-m "$model")
    [[ -n $effort ]] && common+=(-c "model_reasoning_effort=\"$effort\"")
    [[ ${CODEX_WORKER_NETWORK:-} == 1 ]] && common+=(-c 'sandbox_workspace_write.network_access=true')
    if [[ $mode == start ]]; then
      cmd=(codex exec "${common[@]}" -s workspace-write -C "$repo" -)
    else
      # `exec resume` has no -s/-C: set the sandbox via config and run from the repo.
      cmd=(codex exec resume "${common[@]}" -c 'sandbox_mode="workspace-write"' "$sid" -)
    fi
    ;;
  claude)
    cmd=(claude -p --output-format stream-json --verbose --permission-mode acceptEdits --permission-prompts none)
    [[ -n $model ]] && cmd+=(--model "$model")
    [[ -n $effort ]] && cmd+=(--effort "$effort")
    [[ $mode == resume ]] && cmd+=(--resume "$sid")
    cmd+=(--disallowedTools "${claude_denied[@]}" --allowedTools "${claude_tools[@]}")
    ;;
  cursor)
    # The prompt comes in on stdin (verified); output is one JSON result object.
    # File edits work in -p mode as is; shell commands need --force, so it is opt-in.
    # The sandbox exists only on macOS/Linux (the CLI refuses --sandbox enabled on Windows).
    cmd=("$cursor_cli" -p --output-format json --trust)
    [[ ${CURSOR_WORKER_FORCE:-} == 1 ]] && cmd+=(--force)
    case $(uname -s) in MINGW*|MSYS*|CYGWIN*) ;; *) cmd+=(--sandbox enabled) ;; esac
    [[ -n $model ]] && cmd+=(--model "$model")
    [[ $mode == resume ]] && cmd+=(--resume "$sid")
    ;;
esac

pre_head=$(git -C "$root" rev-parse -q --verify HEAD || echo none)
snapshot | sort >"$run_dir/pre-status.tsv"

started=$(date +%s)
(cd "$repo" && export AGENT_DISPATCH_WORKER=1 && "${cmd[@]}" <"$prompt" >"$events" 2>"$run_dir/stderr.log")
worker_exit=$?
elapsed=$(($(date +%s) - started))

post_head=$(git -C "$root" rev-parse -q --verify HEAD || echo none)
snapshot | sort >"$run_dir/post-status.tsv"

# A path changed during the run if its (path, hash) line exists in only one snapshot.
sort "$run_dir/pre-status.tsv" "$run_dir/post-status.tsv" | uniq -u | cut -f1 | sort -u >"$run_dir/changed-files.txt"

# Files the worker committed are clean in both snapshots; add them from the new commits.
: >"$run_dir/commits.txt"
if [[ $pre_head != "$post_head" && $post_head != none ]]; then
  if [[ $pre_head != none ]]; then
    git -C "$root" log --oneline "$pre_head..$post_head" >"$run_dir/commits.txt" 2>/dev/null
    committed=$(git -C "$root" diff --name-only "$pre_head" "$post_head")
  else
    git -C "$root" log --oneline "$post_head" >"$run_dir/commits.txt" 2>/dev/null
    committed=$(git -C "$root" ls-tree -r --name-only "$post_head")
  fi
  { cat "$run_dir/changed-files.txt"; [[ -n $committed ]] && printf '%s\n' "$committed"; } | sort -u >"$run_dir/changed-files.new"
  mv "$run_dir/changed-files.new" "$run_dir/changed-files.txt"
fi

session_id= failed= usage=
case $worker in
  codex)
    session_id=$(jq -r 'select(.type=="thread.started") | .thread_id' "$events" 2>/dev/null | head -1)
    failed=$(jq -r 'select(.type=="turn.failed" or .type=="error") | (.error.message // .message // "error")' \
      "$events" 2>/dev/null | head -3)
    usage=$(jq -c 'select(.type=="turn.completed") | .usage' "$events" 2>/dev/null | tail -1)
    jq -r 'select(.type=="item.completed" and .item.type=="command_execution")
           | "\(.item.exit_code)\t\(.item.command)"' "$events" >"$run_dir/commands.tsv" 2>/dev/null
    ;;
  claude)
    session_id=$(jq -r 'select(.type=="system" and .subtype=="init") | .session_id' "$events" 2>/dev/null | head -1)
    failed=$(jq -r 'select(.type=="result" and .is_error==true) | (.result // .subtype // "error")' \
      "$events" 2>/dev/null | head -3)
    usage=$(jq -c 'select(.type=="result") | {usage, total_cost_usd}' "$events" 2>/dev/null | tail -1)
    jq -r 'select(.type=="result") | .result // empty' "$events" >"$run_dir/last-message.md" 2>/dev/null
    # Pair each Bash tool_use with its tool_result; is_error becomes the exit column (0/1).
    jq -r -s '
      (map(.message.content[]? | select(.type == "tool_use" and .name == "Bash") | {key: .id, value: .input.command})
        | from_entries) as $cmd
      | .[] | select(.type == "user") | .message.content[]?
      | select(.type == "tool_result" and ($cmd[.tool_use_id] != null))
      | "\(if .is_error then 1 else 0 end)\t\($cmd[.tool_use_id] | gsub("[\\n\\t]"; " "))"
    ' "$events" >"$run_dir/commands.tsv" 2>/dev/null
    ;;
  cursor)
    session_id=$(jq -r '.session_id // .chatId // empty' "$events" 2>/dev/null | head -1)
    failed=$(jq -r 'select(.is_error==true) | (.result // .subtype // "error")' "$events" 2>/dev/null | head -3)
    usage=$(jq -c 'select(.usage) | .usage' "$events" 2>/dev/null | tail -1)
    jq -r '.result // empty' "$events" >"$run_dir/last-message.md" 2>/dev/null
    : >"$run_dir/commands.tsv"
    ;;
esac
[[ -z $session_id && $mode == resume ]] && session_id=$sid

if [[ -n $session_id ]]; then
  printf 'saved_worker=%q\nsaved_model=%q\nsaved_effort=%q\n' "$worker" "$model" "$effort" \
    >"$state_dir/session-$session_id.env"
fi

# The user's own uncommitted changes are the dirty state before the session's
# first run; keep it so repair rounds don't flag the worker's earlier edits.
baseline="$state_dir/baseline-${session_id:-none}.tsv"
[[ $mode == start && -n $session_id ]] && cp "$run_dir/pre-status.tsv" "$baseline"
[[ -f $baseline ]] || baseline="$run_dir/pre-status.tsv"
cut -f1 "$baseline" | sort -u | comm -12 - "$run_dir/changed-files.txt" >"$run_dir/overlap.txt"

if [[ -n $model ]]; then shown_model=$model
elif [[ $worker == codex ]]; then shown_model="$(config_value model) (config default)"
else shown_model="(CLI default)"; fi
if [[ -n $effort ]]; then shown_effort=$effort
elif [[ $worker == codex ]]; then shown_effort="$(config_value model_reasoning_effort) (config default)"
else shown_effort="(CLI default)"; fi

# "completed" means the worker process finished cleanly, not that the Master accepted the work.
status=completed
[[ $worker_exit != 0 || -n $failed ]] && status=failed
jq -n \
  --arg run_id "$(basename "$run_dir")" --arg mode "$mode" --arg worker "$worker" \
  --arg model "$model" --arg effort "$effort" --arg session_id "$session_id" \
  --arg status "$status" --argjson exit_code "$worker_exit" --argjson elapsed "$elapsed" \
  --arg workspace "$repo" --arg input "$input" --arg head_before "$pre_head" --arg head_after "$post_head" \
  --arg error "$failed" --arg usage "$usage" --arg run_dir "$run_dir" \
  --rawfile changed "$run_dir/changed-files.txt" --rawfile overlap "$run_dir/overlap.txt" \
  --rawfile commits "$run_dir/commits.txt" --rawfile commands "$run_dir/commands.tsv" '
  def lines: split("\n") | map(select(length > 0));
  def opt: if . == "" or . == "none" then null else . end;
  {
    run_id: $run_id, mode: $mode, worker: $worker,
    model: ($model | opt), effort: ($effort | opt), session_id: ($session_id | opt),
    status: $status, exit_code: $exit_code, elapsed_s: $elapsed, error: ($error | opt),
    workspace: $workspace, input_file: $input,
    head_before: ($head_before | opt), head_after: ($head_after | opt),
    head_moved: ($head_before != $head_after),
    changed_files: ($changed | lines),
    user_files_touched: ($overlap | lines),
    commits: ($commits | lines),
    commands: {total: ($commands | lines | length),
               failed: ($commands | lines | map(select(startswith("0\t") | not)) | length)},
    usage: (try ($usage | fromjson) catch null),
    evidence: {
      prompt: "\($run_dir)/prompt.md", events: "\($run_dir)/events.jsonl",
      report: "\($run_dir)/last-message.md", commands: "\($run_dir)/commands.tsv",
      stderr: "\($run_dir)/stderr.log", summary: "\($run_dir)/summary.txt"
    }
  }' >"$run_dir/summary.json"

{
  echo "== worker-run =="
  echo "mode:        $mode"
  echo "worker:      $worker"
  echo "repo:        $repo"
  echo "model:       $shown_model"
  echo "effort:      $shown_effort"
  echo "run_dir:     $run_dir"
  echo "session_id:  ${session_id:-unknown}"
  echo "exit_code:   $worker_exit  (elapsed ${elapsed}s)"
  [[ -n $failed ]] && echo "worker_error: $failed"
  [[ -n $usage ]] && echo "usage:       $usage"
  if [[ $pre_head != "$post_head" ]]; then
    echo "WARNING: HEAD moved during the run ($pre_head -> $post_head). The worker created commits; inspect with git log."
    [[ -s $run_dir/commits.txt ]] && sed 's/^/  /' "$run_dir/commits.txt"
  fi
  echo
  echo "Files changed during this run ($(wc -l <"$run_dir/changed-files.txt" | tr -d ' ')):"
  sed 's/^/  /' "$run_dir/changed-files.txt"
  if [[ -s $run_dir/overlap.txt ]]; then
    echo
    echo "WARNING: these files had uncommitted user changes before the worker started and were touched in this run:"
    sed 's/^/  /' "$run_dir/overlap.txt"
  fi
  echo
  echo "Commands run: $(wc -l <"$run_dir/commands.tsv" | tr -d ' ') (non-zero exits: $(awk -F'\t' '$1!="0"' "$run_dir/commands.tsv" | wc -l | tr -d ' ')) -> $run_dir/commands.tsv"
  echo "Worker final report: $run_dir/last-message.md"
  echo "Structured summary: $run_dir/summary.json"
} | tee "$run_dir/summary.txt"

exit "$worker_exit"
