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
#   -w, --worker <name>    codex | claude | cursor (default: codex, or policy default)
#   -m, --model <model>    model (default: explicit -> session -> env -> policy -> CLI config -> CLI default)
#   -e, --effort <level>   reasoning effort (default: explicit -> session -> env -> policy -> CLI config -> CLI default)
#                          cursor has no effort flag: -m gpt-5.6-sol -e high runs gpt-5.6-sol-high
#                          (looked up in `agent models`; else passed as model[effort=high]).
#   A resume reuses the worker, model, effort and task_id of the session's first run unless overridden.
#
# Env (optional):
#   CODEX_WORKER_NETWORK=1      codex: allow network inside the workspace-write sandbox
#   CLAUDE_WORKER_TOOLS="..."   claude: tools to allow (default: "Read Edit Write Glob Grep Bash")
#   CLAUDE_WORKER_SLIM=0|1      claude: skip global skills/MCP in worker mode (default: 1)
#   CURSOR_WORKER_FORCE=1       cursor: allow shell commands (--force)
#   AGENT_DISPATCH_STATE=<dir>  where persistent state lives (default: $XDG_STATE_HOME/agent-dispatch,
#                               else ~/.local/state/agent-dispatch)
#
# Output: a run directory under $TMPDIR/agent-dispatch (printed at the end) holding
# prompt.md, events.jsonl, stderr.log, last-message.md, commands.tsv, changed-files.txt,
# commits.txt, summary.txt and summary.json, plus a persistent task/run ledger record under
# $AGENT_DISPATCH_STATE/records/<task_id>/<run_id>.json.
#
# Only one worker runs per work tree at a time (lock: <git dir>/agent-dispatch.lock).
# The worker runs with AGENT_DISPATCH_WORKER=1, and this script refuses to start under it.
#
# Exit status: the worker's own exit code; 2 for usage/setup/policy/security errors;
# 3 if the work tree is locked by another running worker.
set -uo pipefail
umask 077

die() { echo "worker-run: $*" >&2; exit 2; }

usage() {
  die "usage: worker-run.sh [-w codex|claude|cursor] [-m model] [-e effort] start <repo_dir> <task_file> | resume <repo_dir> <session_id> <feedback_file> | models"
}

script_dir="$(cd "$(dirname "$0")" && pwd)"
normalize_jq="$script_dir/normalize-usage.jq"

# Persistent state lives in the user's state dir; per-run raw evidence stays in temp.
state_dir="${AGENT_DISPATCH_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-dispatch}"
sessions_dir="$state_dir/sessions"
records_dir="$state_dir/records"
policy_file="$state_dir/policy.json"
runs_dir="${TMPDIR:-/tmp}/agent-dispatch"
codex_home=${CODEX_HOME:-$HOME/.codex}
models_cache="$codex_home/models_cache.json"
read -r -a claude_tools <<<"${CLAUDE_WORKER_TOOLS:-Read Edit Write Glob Grep Bash}"
# Git writes a worker must never run: the repo owner commits, merges and pushes.
claude_denied=("Bash(git commit *)" "Bash(git push *)" "Bash(git merge *)" "Bash(git rebase *)"
  "Bash(git reset *)" "Bash(git checkout *)" "Bash(git stash *)" "Bash(git clean *)" "Bash(git restore *)")

# Reject symlinked directories to prevent symlink traversal attacks.
ensure_safe_dir() {
  local d=$1
  [[ ! -L $d ]] || die "refusing to use symlinked directory: $d"
  mkdir -p "$d" 2>/dev/null || die "cannot create directory: $d"
  [[ -d $d && ! -L $d ]] || die "invalid directory: $d"
  chmod 700 "$d" 2>/dev/null || true
}

# Write content atomically via a temporary file inside the target directory.
atomic_write() {
  local target=$1 content=$2 dir tmpf
  dir=$(dirname "$target")
  ensure_safe_dir "$dir"
  [[ ! -L $target ]] || die "refusing to overwrite symlink: $target"
  tmpf=$(mktemp "$dir/.tmp.XXXXXX") || die "cannot create temp file in $dir"
  chmod 600 "$tmpf" 2>/dev/null || true
  printf '%s\n' "$content" >"$tmpf" || { rm -f "$tmpf"; die "failed to write $target"; }
  mv -f "$tmpf" "$target" || { rm -f "$tmpf"; die "failed to replace $target"; }
}

# Validate session_id against path traversal and shell metacharacters.
validate_session_id() {
  local s=$1
  [[ -n $s && ${#s} -le 256 && $s != "." && $s != ".." && $s != *".."* && $s =~ ^[A-Za-z0-9._:@-]+$ ]] ||
    die "invalid session_id '$s' (path traversal or unsafe characters rejected)"
}

# Portable SHA-256 hex digest for hashing (worker + session_id).
hash_key() {
  local input=$1
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$input" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$input" | shasum -a 256 | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    printf '%s' "$input" | openssl dgst -sha256 | awk '{print $NF}'
  else
    die "sha256sum, shasum, or openssl is required"
  fi
}

# Strictly parse legacy session-<sid>.env without ever calling `source` or `eval`.
# Only accepts `saved_worker=...`, `saved_model=...`, `saved_effort=...` with safe literal values.
parse_legacy_session_env() {
  local env_file=$1 line key val
  [[ ! -L $env_file && -f $env_file ]] || die "unsafe or missing legacy session file: $env_file"
  saved_worker= saved_model= saved_effort=
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ -z $line ]] && continue
    # Reject any command substitution, chaining, redirection, backticks, or control chars.
    if [[ $line == *[\;\|\&\$\`\(\)\<\>]* ]]; then
      die "malformed or unsafe legacy session file (shell metacharacters rejected): $env_file"
    fi
    if [[ $line =~ ^(saved_worker|saved_model|saved_effort)=(.*)$ ]]; then
      key=${BASH_REMATCH[1]}
      val=${BASH_REMATCH[2]}
      # Strip matching single or double quotes, or printf %q backslash-escapes for safe chars.
      if [[ $val == "''" || $val == '""' ]]; then
        val=""
      elif [[ $val =~ ^\'([^\']*)\'$ ]]; then
        val=${BASH_REMATCH[1]}
      elif [[ $val =~ ^\"([^\"]*)\"$ ]]; then
        val=${BASH_REMATCH[1]}
      else
        # Unquoted printf %q value: allow only safe identifier/model chars and escaped brackets/spaces.
        val=${val//\\\[/[}
        val=${val//\\\]/]}
        val=${val//\\:/:}
        val=${val//\\@/@}
      fi
      [[ $val =~ ^[A-Za-z0-9._:@/=-]*$ ]] ||
        die "malformed or unsafe value for $key in legacy session file: $env_file"
      case $key in
        saved_worker) saved_worker=$val ;;
        saved_model)  saved_model=$val ;;
        saved_effort) saved_effort=$val ;;
      esac
    else
      die "malformed or unsafe line in legacy session file: $env_file"
    fi
  done <"$env_file"
  if [[ -n $saved_worker && ! $saved_worker =~ ^(codex|claude|cursor)$ ]]; then
    die "invalid worker '$saved_worker' in legacy session file: $env_file"
  fi
}

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

command -v jq >/dev/null || die "jq is required"

worker_source="default"
model_source="CLI default"
effort_source="CLI default"
[[ $worker_set == 1 ]] && worker_source="explicit"
[[ $model_set == 1 ]] && model_source="explicit"
[[ $effort_set == 1 ]] && effort_source="explicit"

# A resume keeps the session's original worker, model, effort and task_id unless overridden.
have_saved=0
saved_task_id=
saved_round=0
saved_cum_cost=0
session_file_found=

if [[ $mode == resume ]]; then
  sid=$3
  validate_session_id "$sid"
  # Look up session JSON by sha256(worker:sid). If -w was not explicitly passed, probe known workers.
  if [[ $worker_set == 1 ]]; then
    probe_workers=("$worker" codex claude cursor)
  else
    probe_workers=(codex claude cursor)
  fi
  for pw in "${probe_workers[@]}"; do
    cand_hash=$(hash_key "$pw:$sid")
    cand_file="$sessions_dir/$cand_hash.json"
    if [[ -f $cand_file ]]; then
      [[ ! -L $cand_file ]] || die "refusing to read symlinked session file: $cand_file"
      session_file_found=$cand_file
      break
    fi
  done

  if [[ -n $session_file_found ]]; then
    jq -e '.schema_version == 1 and (.worker | type == "string")' "$session_file_found" >/dev/null 2>&1 ||
      die "corrupted session state JSON: $session_file_found"
    saved_worker=$(jq -r '.worker // empty' "$session_file_found")
    saved_model=$(jq -r '.model // empty' "$session_file_found")
    saved_effort=$(jq -r '.effort // empty' "$session_file_found")
    saved_task_id=$(jq -r '.task_id // empty' "$session_file_found")
    saved_round=$(jq -r '.round // 0' "$session_file_found")
    saved_cum_cost=$(jq -r '.cumulative_cost_usd // 0' "$session_file_found")
    have_saved=1
  elif [[ -e "$state_dir/session-$sid.env" || -L "$state_dir/session-$sid.env" ]]; then
    # Migrate legacy session-<sid>.env strictly without executing it; preserve the original file.
    parse_legacy_session_env "$state_dir/session-$sid.env"
    have_saved=1
    mig_worker=${saved_worker:-$worker}
    mig_hash=$(hash_key "$mig_worker:$sid")
    saved_task_id="task-legacy-${mig_hash:0:12}"
    saved_round=0
    saved_cum_cost=0
  fi

  if [[ $have_saved == 1 ]]; then
    if [[ $worker_set == 0 && -n $saved_worker ]]; then
      worker=$saved_worker
      worker_source="session"
    fi
    if [[ $model_set == 0 ]]; then
      model=$saved_model
      [[ -n $model ]] && model_source="session"
    fi
    if [[ $effort_set == 0 ]]; then
      effort=$saved_effort
      [[ -n $effort ]] && effort_source="session"
    fi
  fi
fi

case $worker in
  codex|claude|cursor) ;;
  *) die "unknown worker '$worker' (use codex, claude or cursor)" ;;
esac

# Priority fallback for model and effort: explicit -> session -> env -> policy -> CLI config -> CLI default.
upper=$(printf '%s' "$worker" | tr '[:lower:]' '[:upper:]')  # not ${worker^^}: macOS ships bash 3.2
if [[ $have_saved == 0 ]]; then
  env_model="${upper}_WORKER_MODEL" env_effort="${upper}_WORKER_EFFORT"
  if [[ $model_set == 0 && -n ${!env_model:-} ]]; then
    model=${!env_model}
    model_source="env ($env_model)"
  fi
  if [[ $effort_set == 0 && -n ${!env_effort:-} ]]; then
    effort=${!env_effort}
    effort_source="env ($env_effort)"
  fi
fi

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

repo_arg=$2
repo=$(cd "$repo_arg" 2>/dev/null && pwd) || die "no such directory: $repo_arg"
git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$repo is not inside a git work tree"
root=$(git -C "$repo" rev-parse --show-toplevel)

# Check repository policy if policy.json exists: enforce allowed_workers and apply policy defaults.
if [[ -e $policy_file || -L $policy_file ]]; then
  [[ ! -L $policy_file ]] || die "refusing to read symlinked policy.json: $policy_file"
  jq -e 'type == "object" and (.schema_version == 1 or .schema_version == null)' "$policy_file" >/dev/null 2>&1 ||
    die "corrupted policy.json: $policy_file"

  policy_match=$(jq -c --arg root "$root" '
    (.repositories // {}) as $repos
    | [ $repos | to_entries[]
        | (.key | gsub("\\\\"; "/") | sub("/+$"; "")) as $k
        | ($root | gsub("\\\\"; "/") | sub("/+$"; "")) as $r
        | select(
            $r == $k or
            ((.value.match // "prefix") == "prefix" and ($r | startswith($k + "/")))
          )
        | { key: $k, len: ($k | length), rule: .value }
      ]
    | sort_by(.len) | last // null
  ' "$policy_file")

  if [[ -n $policy_match && $policy_match != "null" ]]; then
    if ! jq -e --arg w "$worker" '
      if (.rule.allowed_workers | type) == "array" then
        (.rule.allowed_workers | index($w)) != null
      else true end
    ' <<<"$policy_match" >/dev/null 2>&1; then
      allowed_list=$(jq -r '.rule.allowed_workers | join(", ")' <<<"$policy_match")
      die "repository policy for '$root' forbids worker '$worker' (allowed: ${allowed_list:-none})"
    fi
  fi

  # Apply policy model/effort defaults if not set via explicit flag, session, or env.
  if [[ $have_saved == 0 ]]; then
    if [[ $model_set == 0 && -z $model ]]; then
      pol_model=$(jq -r --arg w "$worker" --argjson m "${policy_match:-null}" '
        ($m.rule.worker_defaults[$w].model // .worker_defaults[$w].model // empty)
      ' "$policy_file" 2>/dev/null)
      if [[ -n $pol_model ]]; then
        model=$pol_model
        model_source="policy.json"
      fi
    fi
    if [[ $effort_set == 0 && -z $effort ]]; then
      pol_effort=$(jq -r --arg w "$worker" --argjson m "${policy_match:-null}" '
        ($m.rule.worker_defaults[$w].effort // .worker_defaults[$w].effort // empty)
      ' "$policy_file" 2>/dev/null)
      if [[ -n $pol_effort ]]; then
        effort=$pol_effort
        effort_source="policy.json"
      fi
    fi
  fi
fi

raw_model_requested=$model
raw_effort_requested=$effort

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

ensure_safe_dir "$state_dir"
ensure_safe_dir "$sessions_dir"
ensure_safe_dir "$records_dir"
ensure_safe_dir "$runs_dir"

run_id="$(basename "$root")-$(date +%Y%m%d-%H%M%S)-$$"
run_dir="$runs_dir/$run_id"
ensure_safe_dir "$run_dir"
prompt="$run_dir/prompt.md"
cp "$input" "$prompt"
chmod 600 "$prompt" 2>/dev/null || true
events="$run_dir/events.jsonl"
: >"$events" "$run_dir/stderr.log" "$run_dir/last-message.md" "$run_dir/commands.tsv"
chmod 600 "$events" "$run_dir/stderr.log" "$run_dir/last-message.md" "$run_dir/commands.tsv" 2>/dev/null || true

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
    # Trim cold-start fixed tax in worker mode: skip user slash-commands/skills and external MCP servers by default.
    if [[ ${CLAUDE_WORKER_SLIM:-1} != 0 ]]; then
      cmd+=(--disable-slash-commands --strict-mcp-config)
    fi
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

# Run the worker while trapping INT/TERM so we still record post-run evidence and release the lock.
interrupted=0
worker_pid=
on_signal() {
  interrupted=1
  [[ -n $worker_pid ]] && kill -TERM "$worker_pid" 2>/dev/null || true
}
trap 'on_signal' INT TERM

started=$(date +%s)
(cd "$repo" && export AGENT_DISPATCH_WORKER=1 && exec "${cmd[@]}" <"$prompt" >"$events" 2>"$run_dir/stderr.log") &
worker_pid=$!
wait "$worker_pid" 2>/dev/null
worker_exit=$?
if [[ $interrupted == 1 ]]; then
  wait "$worker_pid" 2>/dev/null || true
  [[ $worker_exit == 0 ]] && worker_exit=130
fi
finished=$(date +%s)
elapsed=$((finished - started))

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

session_id= failed=
case $worker in
  codex)
    session_id=$(jq -r 'select(.type=="thread.started") | .thread_id' "$events" 2>/dev/null | head -1)
    failed=$(jq -r 'select(.type=="turn.failed" or .type=="error") | (.error.message // .message // "error")' \
      "$events" 2>/dev/null | head -3)
    jq -r 'select(.type=="item.completed" and .item.type=="command_execution")
           | "\(.item.exit_code)\t\(.item.command)"' "$events" >"$run_dir/commands.tsv" 2>/dev/null
    ;;
  claude)
    session_id=$(jq -r 'select(.type=="system" and .subtype=="init") | .session_id' "$events" 2>/dev/null | head -1)
    failed=$(jq -r 'select(.type=="result" and .is_error==true) | (.result // .subtype // "error")' \
      "$events" 2>/dev/null | head -3)
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
    jq -r '.result // empty' "$events" >"$run_dir/last-message.md" 2>/dev/null
    : >"$run_dir/commands.tsv"
    ;;
esac
[[ $interrupted == 1 && -z $failed ]] && failed="interrupted by signal"
[[ -z $session_id && $mode == resume ]] && session_id=$sid
if [[ -n $session_id ]]; then
  validate_session_id "$session_id"
fi

# Normalize usage across Codex, Claude, and Cursor via normalize-usage.jq.
model_for_usage=${model:-$([[ $worker == codex ]] && config_value model || true)}
prev_cost_arg=0
[[ $mode == resume && -n $saved_cum_cost ]] && prev_cost_arg=$saved_cum_cost
if [[ -f $normalize_jq ]]; then
  usage_json=$(jq -s \
    --arg provider "$worker" \
    --arg model_requested "$model_for_usage" \
    --argjson prev_cost "${prev_cost_arg:-0}" \
    -f "$normalize_jq" "$events" 2>/dev/null)
fi
if [[ -z ${usage_json:-} ]]; then
  usage_json=$(jq -n --arg m "$model_for_usage" '{
    schema_version: 1, model_requested: (if $m == "" then null else $m end), model_resolved: null,
    input_uncached_tokens: null, input_tokens: null, cache_read_tokens: null, cache_write_tokens: null,
    output_tokens: null, reasoning_tokens: null, total_tokens: null,
    cost_usd: null, cost_kind: null, source: null
  }')
fi

# Determine task_id and round number (start creates a new task_id; resume continues the same task_id).
if [[ $mode == start ]]; then
  task_id="task-$(date -u +%Y%m%d-%H%M%S)-$$"
  round=0
else
  if [[ -n $saved_task_id ]]; then
    task_id=$saved_task_id
  elif [[ -n $session_id ]]; then
    thash=$(hash_key "$worker:$session_id")
    task_id="task-${thash:0:12}"
  else
    task_id="task-$(date -u +%Y%m%d-%H%M%S)-$$"
  fi
  round=$((saved_round + 1))
fi

# Save session state as JSON under $state_dir/sessions/<sha256(worker:session_id)>.json.
session_hash=
if [[ -n $session_id ]]; then
  session_hash=$(hash_key "$worker:$session_id")
  session_json_path="$sessions_dir/$session_hash.json"
  # Track Claude's cumulative session cost so subsequent resumes compute incremental cost accurately.
  new_cum_cost=$saved_cum_cost
  if [[ $worker == claude ]]; then
    reported_cum=$(jq -r 'select(.type=="result") | .total_cost_usd // empty' "$events" 2>/dev/null | tail -1)
    [[ -n $reported_cum && $reported_cum =~ ^[0-9.]+$ ]] && new_cum_cost=$reported_cum
  fi
  created_epoch=$started
  if [[ -f $session_json_path && ! -L $session_json_path ]]; then
    created_epoch=$(jq -r --argjson d "$started" '.created_at_epoch // $d' "$session_json_path" 2>/dev/null || echo "$started")
  fi
  # Store pre-Cursor-resolution model/effort if Cursor folded effort into model?
  # Keep the exact model/effort expectations so resume without -m/-e reproduces the first run.
  save_model=$model
  save_effort=$effort
  if [[ $worker == cursor && -n $raw_effort_requested && -n $raw_model_requested ]]; then
    save_model=$raw_model_requested
    save_effort=$raw_effort_requested
  fi
  session_payload=$(jq -n \
    --arg task_id "$task_id" \
    --arg session_id "$session_id" \
    --arg worker "$worker" \
    --arg model "$save_model" \
    --arg effort "$save_effort" \
    --arg workspace "$repo" \
    --argjson round "$round" \
    --argjson cum_cost "${new_cum_cost:-0}" \
    --argjson created "$created_epoch" \
    --argjson updated "$finished" '
    def opt: if . == "" or . == "none" then null else . end;
    {
      schema_version: 1,
      task_id: $task_id,
      session_id: $session_id,
      worker: $worker,
      model: ($model | opt),
      effort: ($effort | opt),
      round: $round,
      cumulative_cost_usd: $cum_cost,
      workspace: $workspace,
      created_at_epoch: $created,
      updated_at_epoch: $updated
    }')
  atomic_write "$session_json_path" "$session_payload"
fi

# The user's own uncommitted changes are the dirty state before the session's
# first run; keep it so repair rounds don't flag the worker's earlier edits.
if [[ -n $session_hash ]]; then
  baseline="$sessions_dir/baseline-$session_hash.tsv"
  # Fallback to legacy baseline-<sid>.tsv if present from an older session.
  if [[ $mode == resume && ! -f $baseline && -f "$state_dir/baseline-$session_id.tsv" && ! -L "$state_dir/baseline-$session_id.tsv" ]]; then
    baseline="$state_dir/baseline-$session_id.tsv"
  fi
else
  baseline="$run_dir/pre-status.tsv"
fi
if [[ $mode == start && -n $session_hash ]]; then
  [[ ! -L $baseline ]] || die "refusing to write symlinked baseline: $baseline"
  cp "$run_dir/pre-status.tsv" "$baseline"
  chmod 600 "$baseline" 2>/dev/null || true
fi
[[ -f $baseline ]] || baseline="$run_dir/pre-status.tsv"
cut -f1 "$baseline" | sort -u | comm -12 - "$run_dir/changed-files.txt" >"$run_dir/overlap.txt"

if [[ -n $model ]]; then
  shown_model="$model ($model_source)"
elif [[ $worker == codex ]]; then
  cfg_m=$(config_value model)
  model_source="config default"
  shown_model="${cfg_m:-default} (config default)"
else
  shown_model="(CLI default)"
fi

if [[ -n $effort ]]; then
  shown_effort="$effort ($effort_source)"
elif [[ $worker == codex ]]; then
  cfg_e=$(config_value model_reasoning_effort)
  effort_source="config default"
  shown_effort="${cfg_e:-default} (config default)"
else
  shown_effort="(CLI default)"
fi

# "completed" means the worker process finished cleanly, not that the Master accepted the work.
status=completed
[[ $worker_exit != 0 || -n $failed ]] && status=failed

summary_payload=$(jq -n \
  --arg task_id "$task_id" --arg run_id "$run_id" --argjson round "$round" \
  --arg mode "$mode" --arg worker "$worker" \
  --arg model "$model" --arg effort "$effort" --arg session_id "$session_id" \
  --arg worker_source "$worker_source" --arg model_source "$model_source" --arg effort_source "$effort_source" \
  --arg status "$status" --argjson exit_code "$worker_exit" \
  --argjson started_at "$started" --argjson finished_at "$finished" --argjson elapsed "$elapsed" \
  --arg workspace "$repo" --arg input "$input" --arg head_before "$pre_head" --arg head_after "$post_head" \
  --arg error "$failed" --argjson usage "$usage_json" --arg run_dir "$run_dir" \
  --rawfile changed "$run_dir/changed-files.txt" --rawfile overlap "$run_dir/overlap.txt" \
  --rawfile commits "$run_dir/commits.txt" --rawfile commands "$run_dir/commands.tsv" '
  def lines: split("\n") | map(gsub("\r$"; "")) | map(select(length > 0));
  def opt: if . == "" or . == "none" then null else . end;
  {
    schema_version: 1,
    task_id: $task_id,
    run_id: $run_id,
    round: $round,
    mode: $mode,
    worker: $worker,
    model: ($model | opt),
    effort: ($effort | opt),
    resolution: {
      worker_source: $worker_source,
      model_source: $model_source,
      effort_source: $effort_source
    },
    session_id: ($session_id | opt),
    status: $status,
    exit_code: $exit_code,
    started_at_epoch: $started_at,
    finished_at_epoch: $finished_at,
    elapsed_s: $elapsed,
    error: ($error | opt),
    workspace: $workspace,
    input_file: $input,
    head_before: ($head_before | opt),
    head_after: ($head_after | opt),
    head_moved: ($head_before != $head_after),
    changed_files: ($changed | lines),
    user_files_touched: ($overlap | lines),
    commits: ($commits | lines),
    commands: {
      total: ($commands | lines | length),
      failed: ($commands | lines | map(select(startswith("0\t") | not)) | length)
    },
    usage: $usage,
    evidence: {
      prompt: "\($run_dir)/prompt.md",
      events: "\($run_dir)/events.jsonl",
      report: "\($run_dir)/last-message.md",
      commands: "\($run_dir)/commands.tsv",
      stderr: "\($run_dir)/stderr.log",
      summary: "\($run_dir)/summary.txt"
    }
  }')

atomic_write "$run_dir/summary.json" "$summary_payload"

# Persist structured task/run ledger record (without prompt/raw output contents) under $records_dir/<task_id>/<run_id>.json.
ledger_payload=$(jq 'del(.input_file) + {run_dir: .evidence.summary | sub("/summary\\.txt$"; "")}' <<<"$summary_payload")
atomic_write "$records_dir/$task_id/$run_id.json" "$ledger_payload"

usage_compact=$(jq -c '.' <<<"$usage_json")
{
  echo "== worker-run =="
  echo "task_id:     $task_id  (round $round)"
  echo "mode:        $mode"
  echo "worker:      $worker ($worker_source)"
  echo "repo:        $repo"
  echo "model:       $shown_model"
  echo "effort:      $shown_effort"
  echo "run_dir:     $run_dir"
  echo "session_id:  ${session_id:-unknown}"
  echo "exit_code:   $worker_exit  (elapsed ${elapsed}s)"
  [[ -n $failed ]] && echo "worker_error: $failed"
  echo "usage:       $usage_compact"
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
chmod 600 "$run_dir/summary.txt" 2>/dev/null || true

exit "$worker_exit"
