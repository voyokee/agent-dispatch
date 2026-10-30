#!/usr/bin/env bash
# Comprehensive regression suite for v0.2/v0.3 capabilities:
#   Q01-Q04: Quota state, TTL expiration, corruption handling
#   R01-R05: Advisory routing, explicit worker choice, repository policy, zero worker invocations
#   U01-U05: Unified usage schema (Codex cache dedup, Claude 4-way + resume cost delta, Cursor null/real, multi-event, missing model/cost)
#   T01-T05: Task Ledger (start + 2 resumes = 1 task, FAIL->FAIL->PASS stats, idempotent review, unreviewed != PASS, missing_cost_runs)
#   S01-S05: Security hardening (malicious .env no-exec, session_id path traversal, interrupt evidence/lock release, permissions/symlinks, concurrent quota updates)
#   B01-B03: Backward compatibility, explicit vs default priority resolution, install.sh --target all
set -uo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
runner="$here/skills/agent-dispatch/scripts/worker-run.sh"
ctl="$here/skills/agent-dispatch/scripts/dispatchctl.sh"
norm_jq="$here/skills/agent-dispatch/scripts/normalize-usage.jq"
fixtures="$here/tests/fixtures"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/ad-v02.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/state" "$tmp/runs" "$tmp/codex-home"

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "  ok   $*"; }
bad() { fail=$((fail + 1)); echo "  FAIL $*"; }
check() {
  local d=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}

# --- Fake CLIs using fixtures and call counters ---
cat >"$tmp/bin/codex" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo 1 >>"$MOCK_DIR/worker-calls"
echo "$*" >"$MOCK_DIR/codex-args"
echo codex >>work.txt
if [[ -n ${MOCK_SLEEP:-} ]]; then
  echo "$$" >"$MOCK_DIR/worker-sleeping"
  sleep "$MOCK_SLEEP" &
  spid=$!
  trap 'kill -TERM "$spid" 2>/dev/null; exit 130' INT TERM
  wait "$spid"
fi
out=; while [[ $# -gt 0 ]]; do [[ $1 == -o ]] && out=$2; shift; done
[[ -n $out ]] && echo "codex report" >"$out"
if [[ -n ${MOCK_EVENTS_FILE:-} && -f $MOCK_EVENTS_FILE ]]; then
  cat "$MOCK_EVENTS_FILE"
else
  cat "$FIXTURES_DIR/codex-events.jsonl"
fi
EOF

cat >"$tmp/bin/claude" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo 1 >>"$MOCK_DIR/worker-calls"
echo "$*" >"$MOCK_DIR/claude-args"
echo claude >>work.txt
if [[ -n ${MOCK_EVENTS_FILE:-} && -f $MOCK_EVENTS_FILE ]]; then
  cat "$MOCK_EVENTS_FILE"
else
  cat "$FIXTURES_DIR/claude-events.jsonl"
fi
EOF

cat >"$tmp/bin/agent" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == models ]]; then printf 'gpt-5.6-sol\ngpt-5.6-sol-high\ngpt-5.4-mini-low\n'; exit 0; fi
cat >/dev/null
echo 1 >>"$MOCK_DIR/worker-calls"
echo "$*" >"$MOCK_DIR/agent-args"
echo cursor >>work.txt
if [[ -n ${MOCK_EVENTS_FILE:-} && -f $MOCK_EVENTS_FILE ]]; then
  cat "$MOCK_EVENTS_FILE"
else
  cat "$FIXTURES_DIR/cursor-result.json"
fi
EOF
chmod +x "$tmp/bin/"*

export PATH="$tmp/bin:$PATH" MOCK_DIR="$tmp" FIXTURES_DIR="$fixtures" TMPDIR="$tmp/runs" AGENT_DISPATCH_STATE="$tmp/state" CODEX_HOME="$tmp/codex-home"
unset AGENT_DISPATCH_WORKER CODEX_WORKER_MODEL CODEX_WORKER_EFFORT CLAUDE_WORKER_MODEL CLAUDE_WORKER_EFFORT \
  CURSOR_WORKER_MODEL CURSOR_WORKER_EFFORT CURSOR_WORKER_FORCE

echo "do task" >"$tmp/task.md"
echo "fix finding" >"$tmp/feedback.md"
echo "# Master Review: verified" >"$tmp/review.md"

new_repo() {
  local r="$tmp/$1"
  rm -rf "$r"
  git init -q "$r"
  git -C "$r" config user.email test@example.com
  git -C "$r" config user.name tester
  git -C "$r" config core.autocrlf false
  echo base >"$r/work.txt"
  git -C "$r" add -A && git -C "$r" commit -qm init
  echo "$r"
}

run_worker() {
  out=$(bash "$runner" "$@" 2>&1); code=$?
  run_dir=$(sed -n 's/^run_dir: *//p' <<<"$out" | head -1)
  json="$run_dir/summary.json"
}

echo "=== Syntax checks ==="
check "worker-run.sh syntax" bash -n "$runner"
check "dispatchctl.sh syntax" bash -n "$ctl"
check "install.sh syntax" bash -n "$here/install.sh"

# ==============================================================================
# Module 1: Quota & Advisory Router (Q01-Q04, R01-R05)
# ==============================================================================
echo "=== Quota & Advisory Routing (Q01-Q04, R01-R05) ==="
rm -rf "$tmp/state" && mkdir -p "$tmp/state"
: >"$tmp/worker-calls"

# Q01: All providers unconfigured -> all return unknown
q_out=$(bash "$ctl" quota show --json)
check "Q01: unconfigured providers return unknown" jq -e '
  .providers.claude.effective_status == "unknown" and
  .providers.codex.effective_status == "unknown" and
  .providers.cursor.effective_status == "unknown"
' <<<"$q_out"

# Q02: Set Claude limited -> reads status, source, and reason accurately
bash "$ctl" quota set claude limited --ttl-min 60 --reason "approaching 5h cap" >/dev/null
q_out=$(bash "$ctl" quota show --json)
check "Q02: claude limited status & source recorded" jq -e '
  .providers.claude.status == "limited" and
  .providers.claude.effective_status == "limited" and
  .providers.claude.source == "manual" and
  .providers.claude.reason == "approaching 5h cap"
' <<<"$q_out"

# Q03: Quota TTL expired -> effective status becomes unknown while preserving raw_status
jq '.providers.claude.observed_at_epoch = 1000 | .providers.claude.ttl_seconds = 60' "$tmp/state/quota.json" >"$tmp/state/quota.json.tmp"
mv "$tmp/state/quota.json.tmp" "$tmp/state/quota.json"
q_out=$(bash "$ctl" quota show --json)
check "Q03: expired quota returns effective_status=unknown and preserves raw_status" jq -e '
  .providers.claude.status == "unknown" and
  .providers.claude.effective_status == "unknown" and
  .providers.claude.raw_status == "limited" and
  .providers.claude.expired == true
' <<<"$q_out"

# Q04: Corrupted quota.json -> explicit error, recommend refuses to run
echo "{not-valid-json" >"$tmp/state/quota.json"
bash "$ctl" quota show --json >/dev/null 2>&1; q_code=$?
repo_r=$(new_repo repo_r)
bash "$ctl" recommend --repo "$repo_r" --json >/dev/null 2>&1; r_code=$?
check "Q04: corrupted quota.json rejected by quota show and recommend" test "$q_code" = 2 -a "$r_code" = 2
rm -f "$tmp/state/quota.json"

# R01: Codex available, Claude exhausted -> recommends Codex
bash "$ctl" quota set codex available --ttl-min 60 >/dev/null
bash "$ctl" quota set claude exhausted --ttl-min 60 >/dev/null
r_out=$(bash "$ctl" recommend --repo "$repo_r" --json)
check "R01: codex available + claude exhausted -> recommends codex" jq -e '
  .recommended_worker == "codex" and
  (.candidates[] | select(.worker == "claude") | .eligible == false)
' <<<"$r_out"

# R02: User explicitly chooses Claude when limited -> does not silently switch to Codex
bash "$ctl" quota set claude limited --ttl-min 60 --reason "85% used" >/dev/null
r_out=$(bash "$ctl" recommend --repo "$repo_r" --worker claude --json)
check "R02: explicit claude (limited) kept, not silently replaced by codex" jq -e '
  .status == "ok" and
  .explicit_worker == "claude" and
  .recommended_worker == "claude" and
  (.warnings | length > 0)
' <<<"$r_out"

# R03: Repository policy forbids personal providers -> never recommends forbidden workers, and worker-run.sh enforces it
bash "$ctl" policy set --repo "$repo_r" --allow cursor --default-model cursor=gpt-5.4-mini-low >/dev/null
r_out=$(bash "$ctl" recommend --repo "$repo_r" --json)
check "R03a: repo policy allowing only cursor recommends cursor" jq -e '
  .policy_status == "enforced" and
  .recommended_worker == "cursor" and
  .allowed_workers == ["cursor"] and
  .resolution.model == "gpt-5.4-mini-low" and
  .resolution.model_source == "policy.json"
' <<<"$r_out"
bash "$ctl" recommend --repo "$repo_r" --worker codex --json >/dev/null 2>&1; r_forbid=$?
check "R03b: explicit forbidden worker in recommend exits 2" test "$r_forbid" = 2

# R04: All allowed candidates exhausted -> returns recommended_worker=null, does not invoke worker
bash "$ctl" quota set cursor exhausted --ttl-min 60 >/dev/null
r_out=$(bash "$ctl" recommend --repo "$repo_r" --json)
check "R04: all allowed candidates exhausted -> recommended_worker is null" jq -e '
  .status == "no_candidate_available" and .recommended_worker == null
' <<<"$r_out"

# R05: Running recommend only -> zero fake worker invocations
worker_calls=$(wc -l <"$tmp/worker-calls" | tr -d ' ')
check "R05: recommend never invokes any worker CLI (calls=0)" test "$worker_calls" = 0

# Also verify worker-run.sh enforces policy.json when called directly with a forbidden worker
run_worker -w codex start "$repo_r" "$tmp/task.md"
check "R03c: worker-run.sh blocks forbidden worker by repo policy (exit 2)" test "$code" = 2
rm -f "$tmp/state/policy.json" "$tmp/state/quota.json"

# ==============================================================================
# Module 2: Unified Usage Schema (U01-U05)
# ==============================================================================
echo "=== Unified Usage Schema (U01-U05) ==="

# U01: Codex input includes cached tokens -> no double counting
u_codex=$(jq -s --arg provider codex --arg model_requested gpt-5.6-sol -f "$norm_jq" "$fixtures/codex-events.jsonl")
check "U01: Codex uncached (89250-77184=12066) + cached (77184) + out (560) = 89810" jq -e '
  .input_uncached_tokens == 12066 and
  .cache_read_tokens == 77184 and
  .cache_write_tokens == 0 and
  .output_tokens == 560 and
  .reasoning_tokens == 30 and
  .total_tokens == 89810 and
  .cost_usd == null
' <<<"$u_codex"

# U02: Claude has cache write + 4 token categories + resolved model + cost
u_claude=$(jq -s --arg provider claude --arg model_requested haiku -f "$norm_jq" "$fixtures/claude-events.jsonl")
check "U02: Claude 4-way tokens, model_resolved, and cost_usd normalized" jq -e '
  .model_requested == "haiku" and
  .model_resolved == "claude-haiku-5-5" and
  .input_uncached_tokens == 10 and
  .cache_read_tokens == 152040 and
  .cache_write_tokens == 39752 and
  .output_tokens == 1020 and
  .reasoning_tokens == 145 and
  .total_tokens == 192822 and
  .cost_usd == 0.0099818 and
  .cost_kind == "api_equivalent_estimate"
' <<<"$u_claude"

# U03: Cursor with and without usage
u_cursor_real=$(jq -s --arg provider cursor --arg model_requested gpt-5.4-mini-low -f "$norm_jq" "$fixtures/cursor-result.json")
check "U03a: Cursor real usage fields normalized" jq -e '
  .input_uncached_tokens == 15247 and
  .cache_read_tokens == 43776 and
  .cache_write_tokens == 0 and
  .output_tokens == 482 and
  .total_tokens == 59505 and
  .cost_usd == null
' <<<"$u_cursor_real"

u_cursor_null=$(jq -n --arg provider cursor --argjson raw '{"type":"result","result":"done"}' -f "$norm_jq")
check "U03b: Cursor without usage sets token fields to null" jq -e '
  .input_uncached_tokens == null and
  .cache_read_tokens == null and
  .cache_write_tokens == null and
  .output_tokens == null and
  .total_tokens == null and
  .cost_usd == null and
  .source == null
' <<<"$u_cursor_null"

# U04: Multiple usage events (Claude assistant per-step + result cumulative; Claude resume cumulative cost delta)
# In claude-events.jsonl there are 2 assistant usage events (2+8=10) AND 1 final result usage event (10).
# Verify normalize-usage.jq did not sum assistant + result to 20, and handles resume cost delta accurately.
u_claude_resume=$(jq -s --arg provider claude --arg model_requested haiku --argjson prev_cost 0.0099818 -f "$norm_jq" - <<'EOF'
{"type":"system","subtype":"init","session_id":"c3024faa-56ed-4c46-b2a8-0c380fa80df7","model":"claude-haiku-5-5"}
{"type":"assistant","message":{"id":"msg_r1","model":"claude-haiku-5-5","usage":{"input_tokens":6,"cache_creation_input_tokens":2133,"cache_read_input_tokens":121566,"output_tokens":587}}}
{"type":"assistant","message":{"id":"msg_r1","model":"claude-haiku-5-5","usage":{"input_tokens":6,"cache_creation_input_tokens":2133,"cache_read_input_tokens":121566,"output_tokens":587}}}
{"type":"result","is_error":false,"session_id":"c3024faa-56ed-4c46-b2a8-0c380fa80df7","total_cost_usd":0.01191816,"usage":{"input_tokens":6,"cache_creation_input_tokens":2133,"cache_read_input_tokens":121566,"output_tokens":587},"modelUsage":{"claude-haiku-5-5":{"inputTokens":16,"outputTokens":1607,"cacheReadInputTokens":273606,"cacheCreationInputTokens":41885,"costUSD":0.01191816,"canonicalModel":"claude-haiku-5-5","costBasis":"list"}}}
EOF
)
check "U04: multi-event stream & resume cumulative cost delta extracted without double-counting" jq -e '
  .input_uncached_tokens == 6 and
  .cache_write_tokens == 2133 and
  .cache_read_tokens == 121566 and
  .output_tokens == 587 and
  .total_tokens == 124292 and
  .cost_usd == 0.00193636
' <<<"$u_claude_resume"

# U05: Missing model / cost -> never fabricated
u_minimal=$(jq -n --arg provider codex --argjson raw '{"input_tokens":100,"output_tokens":20}' -f "$norm_jq")
check "U05: missing model, cache_write, and cost stay null" jq -e '
  .model_requested == null and
  .model_resolved == null and
  .cache_read_tokens == null and
  .cache_write_tokens == null and
  .cost_usd == null and
  .cost_kind == null and
  .total_tokens == 120
' <<<"$u_minimal"

# ==============================================================================
# Module 3: Task Ledger, Review Verdicts & Stats (T01-T05)
# ==============================================================================
echo "=== Task Ledger, Review & Stats (T01-T05) ==="
rm -rf "$tmp/state" && mkdir -p "$tmp/state"
repo_t=$(new_repo repo_t)

# T01: Start + 2 Resumes belong to the same Task (round 0, 1, 2)
run_worker -w codex -m gpt-5.6-sol -e low start "$repo_t" "$tmp/task.md"
r1_dir=$run_dir
task1=$(jq -r '.task_id' "$r1_dir/summary.json")
sid1=$(jq -r '.session_id' "$r1_dir/summary.json")

run_worker resume "$repo_t" "$sid1" "$tmp/feedback.md"
r2_dir=$run_dir
task2=$(jq -r '.task_id' "$r2_dir/summary.json")

run_worker resume "$repo_t" "$sid1" "$tmp/feedback.md"
r3_dir=$run_dir
task3=$(jq -r '.task_id' "$r3_dir/summary.json")

check "T01: start + 2 resumes share one task_id and increment round (0, 1, 2)" bash -c '
  [[ $1 == "$2" && $2 == "$3" ]] &&
  jq -e ".round == 0" "$4/summary.json" &&
  jq -e ".round == 1" "$5/summary.json" &&
  jq -e ".round == 2" "$6/summary.json"
' _ "$task1" "$task2" "$task3" "$r1_dir" "$r2_dir" "$r3_dir"

# T04: Before any review file is submitted, stats must NOT count completed runs as accepted (PASS)
st_before=$(bash "$ctl" stats --json)
check "T04: completed runs without review verdict are not counted as accepted" jq -e '
  .tasks_started == 1 and
  .tasks_accepted == 0 and
  .tasks_unreviewed == 1 and
  .worker_runs == 3 and
  .repair_rounds == 2
' <<<"$st_before"

# T02: Submit FAIL -> FAIL -> PASS across the 3 runs; stats shows 1 accepted task and 2 repairs
bash "$ctl" review --run "$r1_dir" --verdict FAIL --evidence "$tmp/review.md" >/dev/null
bash "$ctl" review --run "$r2_dir" --verdict FAIL --evidence "$tmp/review.md" >/dev/null
bash "$ctl" review --run "$r3_dir" --verdict PASS --evidence "$tmp/review.md" >/dev/null

st_after=$(bash "$ctl" stats --last 30d --json)
check "T02: FAIL -> FAIL -> PASS counts 1 started, 1 accepted, 2 repairs, 0 first-pass, 3x tokens" jq -e '
  .tasks_started == 1 and
  .tasks_accepted == 1 and
  .first_pass_accepted == 0 and
  .first_pass_acceptance_rate == 0 and
  .worker_runs == 3 and
  .repair_rounds == 2 and
  .tokens.total_tokens == (89810 * 3)
' <<<"$st_after"

# T03: Duplicate review submission is idempotent; conflicting verdict without --force is rejected
bash "$ctl" review --run "$r3_dir" --verdict PASS --evidence "$tmp/review.md" >/dev/null; dup_code=$?
bash "$ctl" review --run "$r3_dir" --verdict FAIL --evidence "$tmp/review.md" >/dev/null 2>&1; conflict_code=$?
st_idem=$(bash "$ctl" stats --json)
check "T03: duplicate PASS is idempotent (exit 0) and conflicting verdict without --force fails (exit 2)" bash -c '
  [[ $1 == 0 && $2 == 2 ]] && jq -e ".tasks_accepted == 1 and .worker_runs == 3" <<<"$3"
' _ "$dup_code" "$conflict_code" "$st_idem"

# T05: Missing cost coverage -> Codex runs have cost_usd=null, Claude run has cost_usd=0.0099818
repo_t2=$(new_repo repo_t2)
run_worker -w claude -m haiku -e low start "$repo_t2" "$tmp/task.md"
bash "$ctl" review --run "$run_dir" --verdict PASS --evidence "$tmp/review.md" >/dev/null
st_cost=$(bash "$ctl" stats --json)
check "T05: stats reports missing_cost_runs=3 and runs_with_cost=1 instead of treating null as \$0" jq -e '
  .tasks_started == 2 and
  .tasks_accepted == 2 and
  .first_pass_accepted == 1 and
  .first_pass_acceptance_rate == 0.5 and
  .cost_coverage.runs_with_cost == 1 and
  .cost_coverage.missing_cost_runs == 3 and
  .missing_cost_runs == 3 and
  .api_equivalent_cost_usd == 0.0099818
' <<<"$st_cost"

# ==============================================================================
# Module 4: Security Hardening (S01-S05)
# ==============================================================================
echo "=== Security Hardening (S01-S05) ==="

# S01: Malicious legacy .env content -> never executed, rejected with exit 2, file preserved
pwn_file="$tmp/pwned_marker"
rm -f "$pwn_file"
mal_env="$tmp/state/session-evil-sid.env"
cat >"$mal_env" <<EOF
saved_worker=codex; touch "$pwn_file"
saved_model=\$(touch "$pwn_file")
EOF
run_worker resume "$repo_t" "evil-sid" "$tmp/feedback.md"
check "S01: malicious legacy .env does not execute shell code, exits 2, and preserves file" bash -c '
  [[ $1 == 2 && ! -e $2 && -f $3 ]]
' _ "$code" "$pwn_file" "$mal_env"

# Also test that a clean legacy .env migrates safely without source
clean_env="$tmp/state/session-clean-legacy.env"
cat >"$clean_env" <<'EOF'
saved_worker=claude
saved_model=haiku
saved_effort=low
EOF
run_worker resume "$repo_t" "clean-legacy" "$tmp/feedback.md"
check "S01b: clean legacy .env migrates safely to JSON session and preserves original .env" bash -c '
  [[ $1 == 0 && -f $2 ]] && jq -e ".worker == \"claude\" and .model == \"haiku\" and .effort == \"low\"" "$3"
' _ "$code" "$clean_env" "$json"

# S02: Illegal session_id -> path traversal rejected
run_worker resume "$repo_t" "../traverse" "$tmp/feedback.md"; c_trav1=$code
run_worker resume "$repo_t" "foo/bar" "$tmp/feedback.md"; c_trav2=$code
run_worker resume "$repo_t" "bad;id" "$tmp/feedback.md"; c_trav3=$code
check "S02: path traversal and unsafe characters in session_id rejected (exit 2)" test "$c_trav1" = 2 -a "$c_trav2" = 2 -a "$c_trav3" = 2

# S03: Worker interrupted by signal -> preserves evidence (summary.json) and releases worktree lock
repo_s3=$(new_repo repo_s3)
rm -f "$tmp/worker-sleeping"
MOCK_SLEEP=30 bash "$runner" start "$repo_s3" "$tmp/task.md" >"$tmp/s3.out" 2>&1 &
s3_pid=$!
# Wait until the worker process is actively running inside worker-run.sh, then send SIGTERM
for _ in {1..150}; do
  [[ -f "$tmp/worker-sleeping" ]] && break
  sleep 0.2
done
kill -TERM "$s3_pid" 2>/dev/null
wait "$s3_pid" 2>/dev/null; s3_code=$?
s3_rd=$(sed -n 's/^run_dir: *//p' "$tmp/s3.out" | head -1)
check "S03: interrupted worker releases lock and still writes summary.json with status=failed" bash -c '
  [[ $1 != 0 && ! -e "$2/.git/agent-dispatch.lock" && -f "$3/summary.json" ]] &&
  jq -e ".status == \"failed\"" "$3/summary.json"
' _ "$s3_code" "$repo_s3" "$s3_rd"

# S04: State and log permissions & symlink protection
ln -s "$tmp/runs" "$tmp/symlink-state" 2>/dev/null || true
if [[ -L "$tmp/symlink-state" ]]; then
  AGENT_DISPATCH_STATE="$tmp/symlink-state" bash "$ctl" quota set codex available >/dev/null 2>&1; sym_code=$?
  check "S04a: symlinked state_dir rejected" test "$sym_code" = 2
else
  ok "S04a: symlink creation skipped on this Windows setup"
fi
case $(uname -s) in
  MINGW*|MSYS*|CYGWIN*)
    check "S04b: state and run files created inside controlled non-symlink directories (Windows Git Bash)" bash -c '
      [[ -d "$1/sessions" && ! -L "$1/sessions" && -d "$1/records" && ! -L "$1/records" ]]
    ' _ "$tmp/state"
    ;;
  *)
    st_perm=$(stat -c %a "$tmp/state" 2>/dev/null || stat -f %Lp "$tmp/state")
    check "S04b: POSIX directory mode is 700" test "$st_perm" = "700"
    ;;
esac

# S05: Concurrent quota updates -> JSON remains valid and no update is lost
rm -f "$tmp/state/quota.json"
(bash "$ctl" quota set codex available --ttl-min 30 --reason "concurrent-codex" >/dev/null) &
p1=$!
(bash "$ctl" quota set claude limited --ttl-min 45 --reason "concurrent-claude" >/dev/null) &
p2=$!
(bash "$ctl" quota set cursor exhausted --ttl-min 15 --reason "concurrent-cursor" >/dev/null) &
p3=$!
wait "$p1" "$p2" "$p3"
q_conc=$(bash "$ctl" quota show --json)
check "S05: concurrent quota updates do not corrupt JSON or drop updates" jq -e '
  .providers.codex.status == "available" and
  .providers.claude.status == "limited" and
  .providers.cursor.status == "exhausted"
' <<<"$q_conc"

# ==============================================================================
# Module 5: Backward Compatibility & Priority Resolution (B01-B03)
# ==============================================================================
echo "=== Backward Compatibility & Input/Default Priority (B01-B03) ==="

# B01: Explicit input vs default config priority echo + Claude slim mode flag
repo_b1=$(new_repo repo_b1)
cat >"$tmp/codex-home/config.toml" <<'EOF'
model = "gpt-5.6-sol"
model_reasoning_effort = "medium"
EOF
run_worker -w codex start "$repo_b1" "$tmp/task.md"
check "B01a: omitted -m/-e falls back to config.toml and reports source='config default'" bash -c '
  grep -q "model:       gpt-5.6-sol (config default)" <<<"$1" &&
  grep -q "effort:      medium (config default)" <<<"$1" &&
  jq -e ".resolution.model_source == \"config default\" and .resolution.effort_source == \"config default\"" "$2"
' _ "$out" "$json"

CODEX_WORKER_MODEL="gpt-5.6-luna" CODEX_WORKER_EFFORT="high" run_worker -w codex start "$repo_b1" "$tmp/task.md"
check "B01b: env vars override config.toml and report source='env (...)'" jq -e '
  .model == "gpt-5.6-luna" and .effort == "high" and
  .resolution.model_source == "env (CODEX_WORKER_MODEL)" and
  .resolution.effort_source == "env (CODEX_WORKER_EFFORT)"
' "$json"

CODEX_WORKER_MODEL="gpt-5.6-luna" run_worker -w codex -m gpt-5.6-sol -e xhigh start "$repo_b1" "$tmp/task.md"
check "B01c: explicit -m/-e overrides env & config and reports source='explicit'" bash -c '
  grep -q "model:       gpt-5.6-sol (explicit)" <<<"$1" &&
  grep -q "effort:      xhigh (explicit)" <<<"$1" &&
  jq -e ".model == \"gpt-5.6-sol\" and .effort == \"xhigh\" and .resolution.model_source == \"explicit\"" "$2"
' _ "$out" "$json"

run_worker -w claude -m haiku -e low start "$repo_b1" "$tmp/task.md"
check "B01d: claude worker runs with --disable-slash-commands --strict-mcp-config by default" \
  grep -q -- "--disable-slash-commands --strict-mcp-config" "$tmp/claude-args"

# Also test Claude rate_limit_event auto-observation via dispatchctl.sh quota observe
obs_out=$(bash "$ctl" quota observe --events "$fixtures/claude-events.jsonl" --worker claude)
check "B01e: quota observe extracts Claude rate_limit_event" jq -e '
  .providers.claude.status == "available" and .providers.claude.source == "cli_event"
' <<<"$obs_out"

# B02: install.sh --target all installs all new scripts & jq filters
home_b2="$tmp/home_b2"
mkdir -p "$home_b2"
HOME="$home_b2" CLAUDE_CONFIG_DIR= bash "$here/install.sh" --target all >/dev/null 2>&1; b2_code=$?
check "B02: install.sh --target all installs worker-run.sh, dispatchctl.sh, and normalize-usage.jq" bash -c '
  [[ $1 == 0 ]] &&
  [[ -x "$2/.claude/skills/agent-dispatch/scripts/worker-run.sh" ]] &&
  [[ -x "$2/.claude/skills/agent-dispatch/scripts/dispatchctl.sh" ]] &&
  [[ -f "$2/.claude/skills/agent-dispatch/scripts/normalize-usage.jq" ]] &&
  [[ -x "$2/.agents/skills/agent-dispatch/scripts/worker-run.sh" ]] &&
  [[ -x "$2/.agents/skills/agent-dispatch/scripts/dispatchctl.sh" ]] &&
  [[ -f "$2/.agents/skills/agent-dispatch/scripts/normalize-usage.jq" ]]
' _ "$b2_code" "$home_b2"

echo
echo "passed: $pass  failed: $fail"
[[ $fail == 0 ]]
