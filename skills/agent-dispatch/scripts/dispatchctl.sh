#!/usr/bin/env bash
# dispatchctl.sh — quota state management, advisory routing, repository policy,
# Master review verdicts, and task-level ledger statistics for agent-dispatch.
#
# Subcommands:
#   dispatchctl.sh quota show [--json]
#   dispatchctl.sh quota set <claude|codex|cursor> <available|limited|exhausted|unknown> [--ttl-min <min>] [--ttl-sec <sec>] [--reason <text>]
#   dispatchctl.sh quota observe --events <events.jsonl> [--worker claude]
#   dispatchctl.sh policy show [--repo <dir>] [--json]
#   dispatchctl.sh policy set --repo <dir> --allow <w1,w2,...> [--match prefix|exact] [--task-pref <type:w1,w2>] [--default-model <w=m>] [--default-effort <w=e>]
#   dispatchctl.sh recommend [--repo <dir>] [--task-type <type>] [--worker <w>] [--model <m>] [--effort <e>] [--allow-exhausted] [--json]
#   dispatchctl.sh review --run <run_dir_or_id> --verdict <PASS|FAIL|ESCALATE> --evidence <file> [--force] [--notes <text>] [--json]
#   dispatchctl.sh stats [--last <Nd|Nh>] [--worker <codex|claude|cursor>] [--json]
set -uo pipefail
umask 077

die() { echo "dispatchctl: $*" >&2; exit 2; }

state_dir="${AGENT_DISPATCH_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-dispatch}"
quota_file="$state_dir/quota.json"
policy_file="$state_dir/policy.json"
sessions_dir="$state_dir/sessions"
records_dir="$state_dir/records"
config_lock="$state_dir/config.lock"
codex_home=${CODEX_HOME:-$HOME/.codex}

command -v jq >/dev/null || die "jq is required"

ensure_safe_dir() {
  local d=$1
  [[ ! -L $d ]] || die "refusing to use symlinked directory: $d"
  mkdir -p "$d" 2>/dev/null || die "cannot create directory: $d"
  [[ -d $d && ! -L $d ]] || die "invalid directory: $d"
  chmod 700 "$d" 2>/dev/null || true
}

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

owner_alive() {
  local pid=$1 wpid=$2
  [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null && return 0
  [[ -n $wpid ]] && command -v tasklist >/dev/null &&
    MSYS2_ARG_CONV_EXCL='*' tasklist /NH /FI "PID eq $wpid" 2>/dev/null | grep -qw -- "$wpid"
}

acquire_config_lock() {
  ensure_safe_dir "$state_dir"
  local host winpid attempts=0 owner_pid owner_winpid owner_host
  host=$(hostname 2>/dev/null || echo unknown)
  winpid=$(cat /proc/$$/winpid 2>/dev/null || true)
  while ! mkdir "$config_lock" 2>/dev/null; do
    owner_pid=$(sed -n 's/^pid=//p' "$config_lock/owner" 2>/dev/null || true)
    owner_winpid=$(sed -n 's/^winpid=//p' "$config_lock/owner" 2>/dev/null || true)
    owner_host=$(sed -n 's/^host=//p' "$config_lock/owner" 2>/dev/null || true)
    if [[ -n $owner_pid && $owner_host == "$host" ]] && ! owner_alive "$owner_pid" "$owner_winpid"; then
      rm -rf "$config_lock" 2>/dev/null || true
      continue
    fi
    attempts=$((attempts + 1))
    if [[ $attempts -ge 50 ]]; then
      die "timed out waiting for config lock: $config_lock"
    fi
    sleep 0.1 2>/dev/null || sleep 1
  done
  printf 'pid=%s\nwinpid=%s\nhost=%s\n' "$$" "$winpid" "$host" >"$config_lock/owner"
  trap 'rm -rf "$config_lock" 2>/dev/null || true' EXIT
}

release_config_lock() {
  rm -rf "$config_lock" 2>/dev/null || true
}

config_value() {
  [[ -f $codex_home/config.toml ]] || return 0
  awk -v k="$1" '/^\[/{exit} $0 ~ "^"k"[[:space:]]*=" {sub(/^[^=]*=[[:space:]]*/, ""); gsub(/"/, ""); print; exit}' \
    "$codex_home/config.toml"
}

# Validate and read quota.json, computing effective_status with TTL expiration.
read_effective_quota_json() {
  local now
  now=$(date -u +%s)
  if [[ -e $quota_file || -L $quota_file ]]; then
    [[ ! -L $quota_file ]] || die "refusing to read symlinked quota.json: $quota_file"
    if ! jq -e '
      type == "object"
      and .schema_version == 1
      and (.providers | type == "object")
      and ([.providers | to_entries[] | .value.status] | all(. == "available" or . == "limited" or . == "exhausted" or . == "unknown"))
    ' "$quota_file" >/dev/null 2>&1; then
      die "corrupted or invalid quota.json: $quota_file"
    fi
    jq --argjson now "$now" '
      def eval_prov($p):
        ($p // {}) as $orig
        | ($orig.status // "unknown") as $raw
        | ($orig.observed_at_epoch // null) as $obs
        | ($orig.ttl_seconds // null) as $ttl
        | (
            if $raw != "unknown" and ($obs | type) == "number" and ($ttl | type) == "number" then
              ($now >= ($obs + $ttl))
            else false end
          ) as $expired
        | (if $expired then "unknown" else $raw end) as $eff
        | {
            status: $eff,
            effective_status: $eff,
            raw_status: $raw,
            expired: $expired,
            source: ($orig.source // null),
            observed_at_epoch: $obs,
            ttl_seconds: $ttl,
            expires_at_epoch: (if ($obs | type) == "number" and ($ttl | type) == "number" then ($obs + $ttl) else null end),
            reason: ($orig.reason // null)
          };
      {
        schema_version: 1,
        evaluated_at_epoch: $now,
        providers: {
          claude: eval_prov(.providers.claude),
          codex: eval_prov(.providers.codex),
          cursor: eval_prov(.providers.cursor)
        }
      }
    ' "$quota_file"
  else
    jq -n --argjson now "$now" '
      def unknown_prov: {
        status: "unknown",
        effective_status: "unknown",
        raw_status: "unknown",
        expired: false,
        source: null,
        observed_at_epoch: null,
        ttl_seconds: null,
        expires_at_epoch: null,
        reason: null
      };
      {
        schema_version: 1,
        evaluated_at_epoch: $now,
        providers: {
          claude: unknown_prov,
          codex: unknown_prov,
          cursor: unknown_prov
        }
      }
    '
  fi
}

cmd_quota() {
  local sub=${1:-show}
  [[ $# -gt 0 ]] && shift
  case $sub in
    show)
      local as_json=0
      while [[ $# -gt 0 ]]; do
        case $1 in
          --json) as_json=1; shift ;;
          *) die "usage: dispatchctl.sh quota show [--json]" ;;
        esac
      done
      local qjson
      qjson=$(read_effective_quota_json) || exit $?
      if [[ $as_json == 1 ]]; then
        printf '%s\n' "$qjson"
      else
        echo "== Quota Status =="
        jq -r '
          .providers | to_entries[]
          | "\(.key)\teffective=\(.value.effective_status)\traw=\(.value.raw_status)\texpired=\(.value.expired)\tsource=\(.value.source // "-")\treason=\(.value.reason // "-")"
        ' <<<"$qjson"
      fi
      ;;
    set)
      [[ $# -ge 2 ]] || die "usage: dispatchctl.sh quota set <claude|codex|cursor> <available|limited|exhausted|unknown> [--ttl-min <min>] [--ttl-sec <sec>] [--reason <text>]"
      local prov=$1 st=$2
      shift 2
      case $prov in
        claude|codex|cursor) ;;
        *) die "invalid provider '$prov' (must be claude, codex, or cursor)" ;;
      esac
      case $st in
        available|limited|exhausted|unknown) ;;
        *) die "invalid quota status '$st' (must be available, limited, exhausted, or unknown)" ;;
      esac
      local ttl_sec=3600 ttl_given=0 reason="" source="manual" as_json=0
      while [[ $# -gt 0 ]]; do
        case $1 in
          --ttl-min)
            [[ $# -ge 2 ]] || die "--ttl-min requires a value"
            [[ $2 =~ ^[0-9]+$ && $2 -ge 1 && $2 -le 10080 ]] || die "--ttl-min must be an integer between 1 and 10080 (got '$2')"
            ttl_sec=$(( $2 * 60 ))
            ttl_given=1
            shift 2
            ;;
          --ttl-sec)
            [[ $# -ge 2 ]] || die "--ttl-sec requires a value"
            [[ $2 =~ ^[0-9]+$ && $2 -ge 1 && $2 -le 604800 ]] || die "--ttl-sec must be an integer between 1 and 604800 (got '$2')"
            ttl_sec=$2
            ttl_given=1
            shift 2
            ;;
          --reason)
            [[ $# -ge 2 ]] || die "--reason requires a value"
            reason=$2
            shift 2
            ;;
          --source)
            [[ $# -ge 2 ]] || die "--source requires a value"
            source=$2
            shift 2
            ;;
          --json)
            as_json=1
            shift
            ;;
          *) die "unknown option for quota set: $1" ;;
        esac
      done

      acquire_config_lock
      local base_json now updated
      now=$(date -u +%s)
      if [[ -e $quota_file || -L $quota_file ]]; then
        [[ ! -L $quota_file ]] || die "refusing to write symlinked quota.json: $quota_file"
        jq -e 'type == "object" and .schema_version == 1 and (.providers | type == "object")' "$quota_file" >/dev/null 2>&1 ||
          die "corrupted quota.json: $quota_file"
        base_json=$(cat "$quota_file")
      else
        base_json='{"schema_version":1,"providers":{"claude":{"status":"unknown","source":"manual","observed_at_epoch":0,"ttl_seconds":3600,"reason":null},"codex":{"status":"unknown","source":"manual","observed_at_epoch":0,"ttl_seconds":3600,"reason":null},"cursor":{"status":"unknown","source":"manual","observed_at_epoch":0,"ttl_seconds":3600,"reason":null}}}'
      fi
      updated=$(jq \
        --arg p "$prov" \
        --arg st "$st" \
        --arg src "$source" \
        --arg rsn "$reason" \
        --argjson now "$now" \
        --argjson ttl "$ttl_sec" \
        --argjson ttl_given "$ttl_given" '
        .providers[$p] = {
          status: $st,
          source: $src,
          observed_at_epoch: $now,
          ttl_seconds: (if $st == "unknown" and $ttl_given == 0 then null else $ttl end),
          reason: (if $rsn == "" then null else $rsn end)
        }
      ' <<<"$base_json")
      atomic_write "$quota_file" "$updated"
      release_config_lock
      if [[ $as_json == 1 ]]; then
        read_effective_quota_json
      else
        echo "Updated quota for $prov -> $st"
      fi
      ;;
    observe)
      local events_file="" worker_name="claude"
      while [[ $# -gt 0 ]]; do
        case $1 in
          --events) [[ $# -ge 2 ]] || die "--events requires a path"; events_file=$2; shift 2 ;;
          --worker) [[ $# -ge 2 ]] || die "--worker requires a name"; worker_name=$2; shift 2 ;;
          *) die "unknown option for quota observe: $1" ;;
        esac
      done
      [[ -n $events_file && -f $events_file && ! -L $events_file ]] || die "valid --events file is required"
      if [[ $worker_name == "claude" ]]; then
        local rl
        rl=$(jq -c 'select(.type=="rate_limit_event") | .rate_limit_info' "$events_file" 2>/dev/null | tail -1)
        if [[ -n $rl && $rl != "null" ]]; then
          local rl_status util5 util7 resets now ttl_s new_st reason_str
          rl_status=$(jq -r '.status // "allowed"' <<<"$rl")
          util5=$(jq -r '.unifiedWindows.five_hour.utilization // 0' <<<"$rl")
          util7=$(jq -r '.unifiedWindows.seven_day.utilization // 0' <<<"$rl")
          resets=$(jq -r '.resetsAt // .unifiedWindows.five_hour.resetsAt // 0' <<<"$rl")
          now=$(date -u +%s)
          ttl_s=$((resets > now ? resets - now : 3600))
          [[ $ttl_s -lt 60 ]] && ttl_s=60
          [[ $ttl_s -gt 604800 ]] && ttl_s=604800
          if [[ $rl_status != "allowed" ]]; then
            new_st="exhausted"
            reason_str="Claude rate_limit_event status=$rl_status"
          elif awk -v u5="$util5" -v u7="$util7" 'BEGIN { exit !((u5+0) >= 0.85 || (u7+0) >= 0.85) }'; then
            new_st="limited"
            reason_str="Claude rate_limit_event utilization (5h=$util5, 7d=$util7)"
          else
            new_st="available"
            reason_str="Claude rate_limit_event allowed (5h=$util5, 7d=$util7)"
          fi
          cmd_quota set claude "$new_st" --ttl-sec "$ttl_s" --source "cli_event" --reason "$reason_str" >/dev/null
        fi
      fi
      read_effective_quota_json
      ;;
    *)
      die "usage: dispatchctl.sh quota <show|set|observe> ..."
      ;;
  esac
}

read_policy_json() {
  if [[ -e $policy_file || -L $policy_file ]]; then
    [[ ! -L $policy_file ]] || die "refusing to read symlinked policy.json: $policy_file"
    jq -e 'type == "object" and (.schema_version == 1 or .schema_version == null)' "$policy_file" >/dev/null 2>&1 ||
      die "corrupted policy.json: $policy_file"
    cat "$policy_file"
  else
    echo '{"schema_version":1,"default_allowed_workers":["codex","claude","cursor"],"default_preference":["codex","claude","cursor"],"repositories":{}}'
  fi
}

cmd_policy() {
  local sub=${1:-show}
  [[ $# -gt 0 ]] && shift
  case $sub in
    show)
      local as_json=0
      while [[ $# -gt 0 ]]; do
        case $1 in
          --json) as_json=1; shift ;;
          *) shift ;;
        esac
      done
      local pjson
      pjson=$(read_policy_json) || exit $?
      if [[ $as_json == 1 ]]; then
        printf '%s\n' "$pjson"
      else
        jq '.' <<<"$pjson"
      fi
      ;;
    set)
      local repo_dir="" allow_csv="" match_mode="prefix" task_pref="" def_model="" def_effort=""
      while [[ $# -gt 0 ]]; do
        case $1 in
          --repo) [[ $# -ge 2 ]] || die "--repo needs a path"; repo_dir=$2; shift 2 ;;
          --allow) [[ $# -ge 2 ]] || die "--allow needs worker names"; allow_csv=$2; shift 2 ;;
          --match) [[ $# -ge 2 ]] || die "--match needs prefix|exact"; match_mode=$2; shift 2 ;;
          --task-pref) [[ $# -ge 2 ]] || die "--task-pref needs type=w1,w2"; task_pref=$2; shift 2 ;;
          --default-model) [[ $# -ge 2 ]] || die "--default-model needs worker=model"; def_model=$2; shift 2 ;;
          --default-effort) [[ $# -ge 2 ]] || die "--default-effort needs worker=effort"; def_effort=$2; shift 2 ;;
          *) die "unknown option for policy set: $1" ;;
        esac
      done
      [[ -n $repo_dir && -n $allow_csv ]] || die "usage: dispatchctl.sh policy set --repo <dir> --allow <w1,w2,...>"
      [[ $match_mode == "prefix" || $match_mode == "exact" ]] || die "--match must be prefix or exact"
      local resolved_repo
      resolved_repo=$(cd "$repo_dir" 2>/dev/null && pwd) || resolved_repo=$repo_dir
      if git -C "$resolved_repo" rev-parse --show-toplevel >/dev/null 2>&1; then
        resolved_repo=$(git -C "$resolved_repo" rev-parse --show-toplevel)
      fi
      # Validate allowed workers
      local IFS=',' w
      for w in $allow_csv; do
        [[ $w =~ ^(codex|claude|cursor)$ ]] || die "invalid worker '$w' in --allow"
      done

      acquire_config_lock
      local base_pol updated_pol
      base_pol=$(read_policy_json) || exit $?
      updated_pol=$(jq \
        --arg repo "$resolved_repo" \
        --arg allow "$allow_csv" \
        --arg match "$match_mode" \
        --arg tpref "$task_pref" \
        --arg dm "$def_model" \
        --arg de "$def_effort" '
        .schema_version = 1
        | .repositories = (.repositories // {})
        | (.repositories[$repo] // {}) as $cur
        | .repositories[$repo] = (
            $cur + {
              match: $match,
              allowed_workers: ($allow | split(",") | map(select(length > 0)))
            }
            | if $tpref != "" then
                ($tpref | split("=")) as $kv
                | .task_preferences = ((.task_preferences // {}) + { ($kv[0]): ($kv[1] | split(",")) })
              else . end
            | if $dm != "" then
                ($dm | split("=")) as $kv
                | .worker_defaults = ((.worker_defaults // {}) + { ($kv[0]): (((.worker_defaults[$kv[0]]) // {}) + { model: $kv[1] }) })
              else . end
            | if $de != "" then
                ($de | split("=")) as $kv
                | .worker_defaults = ((.worker_defaults // {}) + { ($kv[0]): (((.worker_defaults[$kv[0]]) // {}) + { effort: $kv[1] }) })
              else . end
          )
      ' <<<"$base_pol")
      atomic_write "$policy_file" "$updated_pol"
      release_config_lock
      echo "Updated policy for $resolved_repo"
      ;;
    *)
      die "usage: dispatchctl.sh policy <show|set> ..."
      ;;
  esac
}

cmd_recommend() {
  local repo_arg="." task_type="default" exp_worker="" exp_model="" exp_effort="" allow_exhausted=0 as_json=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --repo) [[ $# -ge 2 ]] || die "--repo requires a path"; repo_arg=$2; shift 2 ;;
      --task-type) [[ $# -ge 2 ]] || die "--task-type requires a value"; task_type=$2; shift 2 ;;
      -w|--worker) [[ $# -ge 2 ]] || die "--worker requires a value"; exp_worker=$2; shift 2 ;;
      -m|--model) [[ $# -ge 2 ]] || die "--model requires a value"; exp_model=$2; shift 2 ;;
      -e|--effort) [[ $# -ge 2 ]] || die "--effort requires a value"; exp_effort=$2; shift 2 ;;
      --allow-exhausted) allow_exhausted=1; shift ;;
      --json) as_json=1; shift ;;
      *) die "unknown option for recommend: $1" ;;
    esac
  done

  if [[ -n $exp_worker && ! $exp_worker =~ ^(codex|claude|cursor)$ ]]; then
    die "unknown worker '$exp_worker' (use codex, claude, or cursor)"
  fi

  local repo_root
  repo_root=$(cd "$repo_arg" 2>/dev/null && pwd) || die "no such directory: $repo_arg"
  if git -C "$repo_root" rev-parse --show-toplevel >/dev/null 2>&1; then
    repo_root=$(git -C "$repo_root" rev-parse --show-toplevel)
  fi

  # Validate and load both quota and policy; corrupted files fail immediately (Q04).
  local qjson pjson
  qjson=$(read_effective_quota_json) || exit $?
  pjson=$(read_policy_json) || exit $?

  local codex_cfg_model codex_cfg_effort
  codex_cfg_model=$(config_value model)
  codex_cfg_effort=$(config_value model_reasoning_effort)

  local rec_json
  rec_json=$(jq -n \
    --arg repo "$repo_root" \
    --arg task_type "$task_type" \
    --arg exp_w "$exp_worker" \
    --arg exp_m "$exp_model" \
    --arg exp_e "$exp_effort" \
    --argjson allow_exh "$allow_exhausted" \
    --argjson quota "$qjson" \
    --argjson policy "$pjson" \
    --arg env_codex_m "${CODEX_WORKER_MODEL:-}" \
    --arg env_codex_e "${CODEX_WORKER_EFFORT:-}" \
    --arg env_claude_m "${CLAUDE_WORKER_MODEL:-}" \
    --arg env_claude_e "${CLAUDE_WORKER_EFFORT:-}" \
    --arg env_cursor_m "${CURSOR_WORKER_MODEL:-}" \
    --arg env_cursor_e "${CURSOR_WORKER_EFFORT:-}" \
    --arg cfg_codex_m "$codex_cfg_model" \
    --arg cfg_codex_e "$codex_cfg_effort" '
    # 1. Match repository policy (exact or longest prefix match)
    (($policy.repositories // {}) | to_entries) as $entries
    | ($repo | gsub("\\\\"; "/") | sub("/+$"; "")) as $norm_repo
    | (
        [ $entries[]
          | (.key | gsub("\\\\"; "/") | sub("/+$"; "")) as $k
          | select(
              $norm_repo == $k or
              ((.value.match // "prefix") == "prefix" and ($norm_repo | startswith($k + "/")))
            )
          | { key: $k, len: ($k | length), rule: .value }
        ] | sort_by(.len) | last // null
      ) as $matched
    | (if $matched != null then "enforced" else "unconfigured_default" end) as $policy_status
    | (
        if $matched != null and ($matched.rule.allowed_workers | type) == "array" then
          $matched.rule.allowed_workers
        elif ($policy.default_allowed_workers | type) == "array" then
          $policy.default_allowed_workers
        else
          ["codex", "claude", "cursor"]
        end
      ) as $allowed

    # 2. Determine task preference order + default tie-break order (codex -> claude -> cursor)
    | (
        ($matched.rule.task_preferences[$task_type] // $policy.task_preferences[$task_type] // [])
        + ($policy.default_preference // ["codex", "claude", "cursor"])
        | unique
      ) as $pref_order
    | [ $pref_order[] | select(. as $w | ($allowed | index($w)) != null) ] as $allowed_ordered

    # Helper to score quota status
    | def quota_rank($st):
        if $st == "available" then 0
        elif $st == "unknown" then 1
        elif $st == "limited" then 2
        else 3 end;

    # Helper to resolve default model & effort for a candidate worker
    def resolve_me($w):
      (if $w == "codex" then $env_codex_m elif $w == "claude" then $env_claude_m else $env_cursor_m end) as $em
      | (if $w == "codex" then $env_codex_e elif $w == "claude" then $env_claude_e else $env_cursor_e end) as $ee
      | ($matched.rule.worker_defaults[$w].model // $policy.worker_defaults[$w].model // "") as $pm
      | ($matched.rule.worker_defaults[$w].effort // $policy.worker_defaults[$w].effort // "") as $pe
      | {
          model: (
            if $exp_m != "" then $exp_m
            elif $em != "" then $em
            elif $pm != "" then $pm
            elif ($w == "codex" and $cfg_codex_m != "") then $cfg_codex_m
            else null end
          ),
          model_source: (
            if $exp_m != "" then "explicit"
            elif $em != "" then "env"
            elif $pm != "" then "policy.json"
            elif ($w == "codex" and $cfg_codex_m != "") then "config.toml"
            else "CLI default" end
          ),
          effort: (
            if $exp_e != "" then $exp_e
            elif $ee != "" then $ee
            elif $pe != "" then $pe
            elif ($w == "codex" and $cfg_codex_e != "") then $cfg_codex_e
            else null end
          ),
          effort_source: (
            if $exp_e != "" then "explicit"
            elif $ee != "" then "env"
            elif $pe != "" then "policy.json"
            elif ($w == "codex" and $cfg_codex_e != "") then "config.toml"
            else "CLI default" end
          )
        };

    # 3. Rank allowed candidates
    [ $allowed_ordered | to_entries[]
      | .value as $w
      | .key as $pref_idx
      | ($quota.providers[$w].effective_status // "unknown") as $qst
      | {
          worker: $w,
          quota_status: $qst,
          quota_raw_status: ($quota.providers[$w].raw_status // "unknown"),
          quota_expired: ($quota.providers[$w].expired // false),
          quota_reason: ($quota.providers[$w].reason // null),
          preference_index: $pref_idx,
          rank_key: ((quota_rank($qst) * 100) + $pref_idx),
          eligible: (if $qst == "exhausted" and $allow_exh == 0 then false else true end)
        }
    ] | sort_by(.rank_key) as $ranked

    # 4. Handle explicit user choice vs advisory recommendation
    | if $exp_w != "" then
        if ($allowed | index($exp_w)) == null then
          {
            schema_version: 1,
            advisory_only: true,
            status: "forbidden_by_policy",
            repository: $repo,
            policy_status: $policy_status,
            allowed_workers: $allowed,
            task_type: $task_type,
            explicit_worker: $exp_w,
            recommended_worker: null,
            resolution: null,
            warnings: ["Explicitly requested worker \($exp_w) is forbidden by repository policy for \($repo)."],
            candidates: $ranked
          }
        else
          ($quota.providers[$exp_w].effective_status // "unknown") as $eq
          | if $eq == "exhausted" and $allow_exh == 0 then
              {
                schema_version: 1,
                advisory_only: true,
                status: "explicit_worker_exhausted",
                repository: $repo,
                policy_status: $policy_status,
                allowed_workers: $allowed,
                task_type: $task_type,
                explicit_worker: $exp_w,
                recommended_worker: null,
                requires_confirmation: true,
                resolution: (resolve_me($exp_w) + { worker_source: "explicit" }),
                warnings: ["Explicitly requested worker \($exp_w) is marked exhausted; pass --allow-exhausted or confirm override."],
                candidates: $ranked
              }
            else
              {
                schema_version: 1,
                advisory_only: true,
                status: "ok",
                repository: $repo,
                policy_status: $policy_status,
                allowed_workers: $allowed,
                task_type: $task_type,
                explicit_worker: $exp_w,
                recommended_worker: $exp_w,
                resolution: (resolve_me($exp_w) + { worker_source: "explicit" }),
                warnings: (
                  if $eq == "limited" then
                    ["Explicitly requested worker \($exp_w) has limited quota; proceeding with user choice without switching worker."]
                  elif $eq == "exhausted" then
                    ["Explicitly requested worker \($exp_w) is marked exhausted; proceeding because --allow-exhausted was set."]
                  else [] end
                ),
                candidates: $ranked
              }
            end
        end
      else
        ([ $ranked[] | select(.eligible == true) ] | first // null) as $top
        | if $top == null then
            {
              schema_version: 1,
              advisory_only: true,
              status: "no_candidate_available",
              repository: $repo,
              policy_status: $policy_status,
              allowed_workers: $allowed,
              task_type: $task_type,
              explicit_worker: null,
              recommended_worker: null,
              resolution: null,
              warnings: ["No eligible worker available (all allowed candidates are exhausted or disallowed)."],
              candidates: $ranked
            }
          else
            {
              schema_version: 1,
              advisory_only: true,
              status: "ok",
              repository: $repo,
              policy_status: $policy_status,
              allowed_workers: $allowed,
              task_type: $task_type,
              explicit_worker: null,
              recommended_worker: $top.worker,
              resolution: (resolve_me($top.worker) + { worker_source: "recommended" }),
              warnings: (
                if $top.quota_status == "limited" then
                  ["Recommended worker \($top.worker) is currently in limited quota state."]
                else [] end
              ),
              candidates: $ranked
            }
          end
      end
  ')

  if [[ $as_json == 1 ]]; then
    printf '%s\n' "$rec_json"
  else
    echo "== Advisory Recommendation =="
    jq -r '
      "status:             \(.status)\n" +
      "repository:         \(.repository) (\(.policy_status))\n" +
      "recommended_worker: \(.recommended_worker // "none")\n" +
      (if .resolution != null then
        "model:              \(.resolution.model // "(CLI default)") (\(.resolution.model_source))\n" +
        "effort:             \(.resolution.effort // "(CLI default)") (\(.resolution.effort_source))\n"
       else "" end) +
      (if (.warnings | length) > 0 then "warnings:\n  " + (.warnings | join("\n  ")) else "" end)
    ' <<<"$rec_json"
  fi
  local st
  st=$(jq -r '.status' <<<"$rec_json")
  [[ $st == "forbidden_by_policy" ]] && exit 2
  return 0
}

cmd_review() {
  local run_arg="" verdict="" evidence="" force=0 notes="" as_json=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --run) [[ $# -ge 2 ]] || die "--run requires a run directory or run_id"; run_arg=$2; shift 2 ;;
      --verdict) [[ $# -ge 2 ]] || die "--verdict requires PASS, FAIL, or ESCALATE"; verdict=$2; shift 2 ;;
      --evidence) [[ $# -ge 2 ]] || die "--evidence requires a path to review.md"; evidence=$2; shift 2 ;;
      --force) force=1; shift ;;
      --notes) [[ $# -ge 2 ]] || die "--notes requires text"; notes=$2; shift 2 ;;
      --json) as_json=1; shift ;;
      *) die "unknown option for review: $1" ;;
    esac
  done

  [[ -n $run_arg && -n $verdict && -n $evidence ]] ||
    die "usage: dispatchctl.sh review --run <run-dir|run-id> --verdict <PASS|FAIL|ESCALATE> --evidence <review.md> [--force]"

  case $verdict in
    PASS|FAIL|ESCALATE) ;;
    *) die "invalid verdict '$verdict' (must be PASS, FAIL, or ESCALATE)" ;;
  esac

  [[ -f $evidence && ! -L $evidence && -s $evidence ]] ||
    die "evidence file must exist, be non-empty, and not be a symlink: $evidence"
  local abs_evidence
  abs_evidence="$(cd "$(dirname "$evidence")" 2>/dev/null && pwd)/$(basename "$evidence")"

  # Locate the persistent run record in $records_dir/<task_id>/<run_id>.json
  local task_id="" run_id="" record_file="" run_dir_path=""
  if [[ -d $run_arg && -f "$run_arg/summary.json" ]]; then
    run_dir_path=$(cd "$run_arg" 2>/dev/null && pwd)
    task_id=$(jq -r '.task_id // empty' "$run_dir_path/summary.json" 2>/dev/null)
    run_id=$(jq -r '.run_id // empty' "$run_dir_path/summary.json" 2>/dev/null)
    if [[ -n $task_id && -n $run_id && -f "$records_dir/$task_id/$run_id.json" ]]; then
      record_file="$records_dir/$task_id/$run_id.json"
    fi
  fi
  if [[ -z $record_file ]]; then
    local base_run
    base_run=$(basename "$run_arg")
    for cand in "$records_dir"/*/"$base_run.json"; do
      if [[ -f $cand && ! -L $cand ]]; then
        record_file=$cand
        task_id=$(jq -r '.task_id // empty' "$cand" 2>/dev/null)
        run_id=$(jq -r '.run_id // empty' "$cand" 2>/dev/null)
        run_dir_path=$(jq -r '.run_dir // empty' "$cand" 2>/dev/null)
        break
      fi
    done
  fi
  [[ -n $record_file && -f $record_file ]] || die "run record not found for '$run_arg'"

  local review_file="${record_file%.json}.review.json"
  acquire_config_lock

  if [[ -e $review_file || -L $review_file ]]; then
    [[ ! -L $review_file ]] || die "refusing to use symlinked review file: $review_file"
    local existing_verdict
    existing_verdict=$(jq -r '.verdict // empty' "$review_file" 2>/dev/null)
    if [[ $existing_verdict == "$verdict" && $force == 0 ]]; then
      # Idempotent re-submission of the same verdict: keep existing record without duplicating or mutating timestamp.
      local existing_json
      existing_json=$(cat "$review_file")
      release_config_lock
      if [[ $as_json == 1 ]]; then
        printf '%s\n' "$existing_json"
      else
        echo "Review verdict for $run_id is already $verdict (idempotent)"
      fi
      return 0
    elif [[ $existing_verdict != "$verdict" && $force == 0 ]]; then
      release_config_lock
      die "run '$run_id' already has verdict '$existing_verdict'; pass --force to overwrite with '$verdict'"
    fi
  fi

  local now review_payload
  now=$(date -u +%s)
  review_payload=$(jq -n \
    --arg task_id "$task_id" \
    --arg run_id "$run_id" \
    --arg verdict "$verdict" \
    --arg evidence "$abs_evidence" \
    --arg notes "$notes" \
    --argjson reviewed_at "$now" '
    {
      schema_version: 1,
      task_id: $task_id,
      run_id: $run_id,
      verdict: $verdict,
      evidence_file: $evidence,
      notes: (if $notes == "" then null else $notes end),
      reviewed_at_epoch: $reviewed_at
    }')

  atomic_write "$review_file" "$review_payload"
  if [[ -n $run_dir_path && -d $run_dir_path && ! -L $run_dir_path ]]; then
    atomic_write "$run_dir_path/review.json" "$review_payload"
  fi
  release_config_lock

  if [[ $as_json == 1 ]]; then
    printf '%s\n' "$review_payload"
  else
    echo "Recorded review verdict $verdict for $run_id (task $task_id)"
  fi
}

cmd_stats() {
  local last_spec="" filter_worker="" as_json=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --last) [[ $# -ge 2 ]] || die "--last requires a duration like 30d or 24h"; last_spec=$2; shift 2 ;;
      -w|--worker) [[ $# -ge 2 ]] || die "--worker requires codex, claude, or cursor"; filter_worker=$2; shift 2 ;;
      --json) as_json=1; shift ;;
      *) die "unknown option for stats: $1" ;;
    esac
  done

  if [[ -n $filter_worker && ! $filter_worker =~ ^(codex|claude|cursor)$ ]]; then
    die "invalid worker '$filter_worker' (use codex, claude, or cursor)"
  fi

  local now cutoff=0
  now=$(date -u +%s)
  if [[ -n $last_spec ]]; then
    if [[ $last_spec =~ ^([0-9]+)d$ ]]; then
      cutoff=$(( now - BASH_REMATCH[1] * 86400 ))
    elif [[ $last_spec =~ ^([0-9]+)h$ ]]; then
      cutoff=$(( now - BASH_REMATCH[1] * 3600 ))
    elif [[ $last_spec =~ ^([0-9]+)m$ ]]; then
      cutoff=$(( now - BASH_REMATCH[1] * 60 ))
    else
      die "invalid --last format '$last_spec' (expected <N>d, <N>h, or <N>m)"
    fi
  fi

  local tmp_items=""
  if [[ -d $records_dir ]]; then
    [[ ! -L $records_dir ]] || die "refusing to read symlinked records_dir: $records_dir"
    local rf revf rjson revjson
    for rf in "$records_dir"/*/*.json; do
      [[ -f $rf ]] || continue
      [[ $rf == *.review.json ]] && continue
      [[ ! -L $rf ]] || die "refusing to read symlinked record: $rf"
      rjson=$(cat "$rf")
      revf="${rf%.json}.review.json"
      if [[ -f $revf && ! -L $revf ]]; then
        revjson=$(cat "$revf")
      else
        revjson="null"
      fi
      tmp_items+=$(jq -c --argjson rev "$revjson" '. + { review: $rev }' <<<"$rjson")$'\n'
    done
  fi

  local stats_json
  stats_json=$(printf '%s' "$tmp_items" | jq -s \
    --arg worker "$filter_worker" \
    --arg last_window "$last_spec" \
    --argjson cutoff "$cutoff" '
    # Group all runs by task_id first so --last filters by task creation time and keeps all subsequent repairs.
    group_by(.task_id)
    | map(
        sort_by(.round // 0, .started_at_epoch // 0)
        | {
            task_id: .[0].task_id,
            created_at_epoch: ([.[].started_at_epoch // 0] | min),
            runs: (
              if $worker == "" then .
              else map(select(.worker == $worker)) end
            )
          }
        | select((.runs | length) > 0)
        | select($cutoff == 0 or .created_at_epoch >= $cutoff)
      ) as $tasks
    | [ $tasks[].runs[] ] as $all_runs
    | ($tasks | length) as $tasks_started
    | (
        [ $tasks[]
          | ([ .runs[] | select(.review != null and (.review.verdict | type) == "string") ] | last) as $last_rev
          | select($last_rev != null and $last_rev.review.verdict == "PASS")
        ] | length
      ) as $tasks_accepted
    | (
        [ $tasks[]
          | ([ .runs[] | select(.review != null and (.review.verdict | type) == "string") ] | last) as $last_rev
          | select($last_rev != null and $last_rev.review.verdict == "FAIL")
        ] | length
      ) as $tasks_failed
    | (
        [ $tasks[]
          | ([ .runs[] | select(.review != null and (.review.verdict | type) == "string") ] | last) as $last_rev
          | select($last_rev != null and $last_rev.review.verdict == "ESCALATE")
        ] | length
      ) as $tasks_escalated
    | (
        [ $tasks[]
          | select(([ .runs[] | select(.review != null and (.review.verdict | type) == "string") ] | length) > 0)
        ] | length
      ) as $tasks_reviewed
    | (
        [ $tasks[]
          | select(
              (.runs | length) == 1
              and (.runs[0].review != null)
              and (.runs[0].review.verdict == "PASS")
            )
        ] | length
      ) as $first_pass_accepted
    | ($all_runs | length) as $worker_runs
    | ([ $tasks[] | ((.runs | length) - 1) | if . < 0 then 0 else . end ] | add // 0) as $repair_rounds
    | ([ $all_runs[].elapsed_s // 0 ] | add // 0) as $worker_time_s
    | ([ $all_runs[] | select(.usage.total_tokens != null) ]) as $usage_runs
    | ($usage_runs | length) as $runs_with_usage
    | ($worker_runs - $runs_with_usage) as $missing_usage_runs
    | ([ $all_runs[] | select(.usage.cost_usd != null) ]) as $cost_runs
    | ($cost_runs | length) as $runs_with_cost
    | ($worker_runs - $runs_with_cost) as $missing_cost_runs
    | {
        schema_version: 1,
        filter: {
          last: (if $last_window == "" then null else $last_window end),
          worker: (if $worker == "" then null else $worker end),
          attribution_rule: "task_created_at_includes_all_repairs"
        },
        tasks_started: $tasks_started,
        tasks_reviewed: $tasks_reviewed,
        tasks_accepted: $tasks_accepted,
        tasks_failed: $tasks_failed,
        tasks_escalated: $tasks_escalated,
        tasks_unreviewed: ($tasks_started - $tasks_reviewed),
        first_pass_accepted: $first_pass_accepted,
        first_pass_acceptance_rate: (
          if $tasks_reviewed == 0 then null
          else (($first_pass_accepted / $tasks_reviewed) * 10000 | round / 10000) end
        ),
        worker_runs: $worker_runs,
        repair_rounds: $repair_rounds,
        worker_time_s: $worker_time_s,
        tokens: {
          input_uncached_tokens: ([ $usage_runs[].usage.input_uncached_tokens // 0 ] | add // 0),
          cache_read_tokens: ([ $usage_runs[].usage.cache_read_tokens // 0 ] | add // 0),
          cache_write_tokens: ([ $usage_runs[].usage.cache_write_tokens // 0 ] | add // 0),
          output_tokens: ([ $usage_runs[].usage.output_tokens // 0 ] | add // 0),
          total_tokens: ([ $usage_runs[].usage.total_tokens // 0 ] | add // 0)
        },
        usage_coverage: {
          runs_with_usage: $runs_with_usage,
          missing_usage_runs: $missing_usage_runs,
          coverage_ratio: (
            if $worker_runs == 0 then null
            else (($runs_with_usage / $worker_runs) * 10000 | round / 10000) end
          )
        },
        api_equivalent_cost_usd: (
          if $runs_with_cost == 0 then null
          else (([ $cost_runs[].usage.cost_usd ] | add) * 100000000 | round / 100000000) end
        ),
        missing_cost_runs: $missing_cost_runs,
        cost_coverage: {
          runs_with_cost: $runs_with_cost,
          missing_cost_runs: $missing_cost_runs,
          coverage_ratio: (
            if $worker_runs == 0 then null
            else (($runs_with_cost / $worker_runs) * 10000 | round / 10000) end
          )
        }
      }
  ')

  if [[ $as_json == 1 ]]; then
    printf '%s\n' "$stats_json"
  else
    echo "== Agent Dispatch Stats =="
    jq -r '
      "Tasks Started:         \(.tasks_started)\n" +
      "Tasks Accepted (PASS): \(.tasks_accepted) (unreviewed: \(.tasks_unreviewed))\n" +
      "First-pass Acceptance: \(if .first_pass_acceptance_rate == null then "N/A" else "\(.first_pass_acceptance_rate * 100)%" end) (\(.first_pass_accepted)/\(.tasks_reviewed))\n" +
      "Worker Runs:           \(.worker_runs) (Repair Rounds: \(.repair_rounds))\n" +
      "Worker Time:           \(.worker_time_s)s\n" +
      "Total Tokens:          \(.tokens.total_tokens) (uncached_in=\(.tokens.input_uncached_tokens), cache_read=\(.tokens.cache_read_tokens), cache_write=\(.tokens.cache_write_tokens), out=\(.tokens.output_tokens))\n" +
      "Usage Coverage:        \(.usage_coverage.runs_with_usage)/\(.worker_runs) (missing: \(.usage_coverage.missing_usage_runs))\n" +
      "API-equivalent Cost:   \(if .api_equivalent_cost_usd == null then "null" else "$\(.api_equivalent_cost_usd)" end) (runs_with_cost=\(.cost_coverage.runs_with_cost), missing_cost_runs=\(.missing_cost_runs))"
    ' <<<"$stats_json"
  fi
}

subcmd=${1:-}
[[ $# -gt 0 ]] && shift
case $subcmd in
  quota)     cmd_quota "$@" ;;
  policy)    cmd_policy "$@" ;;
  recommend) cmd_recommend "$@" ;;
  review)    cmd_review "$@" ;;
  stats)     cmd_stats "$@" ;;
  *)
    die "usage: dispatchctl.sh <quota|policy|recommend|review|stats> ..."
    ;;
esac
