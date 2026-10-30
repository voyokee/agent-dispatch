#!/usr/bin/env bash
# Smoke tests for worker-run.sh and install.sh, using fake codex / claude / agent
# CLIs, so they need no account, network or model quota.
# Usage: tests/smoke.sh        (needs bash, git, jq)
set -uo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
runner="$here/skills/agent-dispatch/scripts/worker-run.sh"
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/ad-smoke.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/state" "$tmp/runs" "$tmp/codex-home"

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "  ok   $*"; }
bad() { fail=$((fail + 1)); echo "  FAIL $*"; }
check() { # check <description> <command...>
  local d=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}

# --- fake CLIs -------------------------------------------------------------
# Each one appends to work.txt in the cwd and prints events in its CLI's format.
# MOCK_NEWFILE=1 creates new.txt; MOCK_COMMIT=1 commits everything; MOCK_FAIL=1 fails.
cat >"$tmp/bin/codex" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo "worker_env=${AGENT_DISPATCH_WORKER:-unset}" >"$MOCK_DIR/codex-env"
echo "$*" >"$MOCK_DIR/codex-args"
echo codex >>work.txt
[[ ${MOCK_NEWFILE:-} == 1 ]] && echo new >new.txt
[[ ${MOCK_COMMIT:-} == 1 ]] && { git add -A && git commit -qm "worker commit"; } >/dev/null 2>&1
out=; while [[ $# -gt 0 ]]; do [[ $1 == -o ]] && out=$2; shift; done
[[ -n $out ]] && echo "codex report" >"$out"
echo '{"type":"thread.started","thread_id":"codex-sid-1"}'
echo '{"type":"item.completed","item":{"type":"command_execution","exit_code":0,"command":"pytest -q"}}'
echo '{"type":"item.completed","item":{"type":"command_execution","exit_code":1,"command":"ruff ."}}'
if [[ ${MOCK_FAIL:-} == 1 ]]; then
  echo '{"type":"turn.failed","error":{"message":"boom"}}'; exit 1
fi
echo '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}'
EOF
cat >"$tmp/bin/claude" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo "$*" >"$MOCK_DIR/claude-args"
echo claude >>work.txt
echo '{"type":"system","subtype":"init","session_id":"claude-sid-1"}'
echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"npm test"}}]}}'
echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":false}]}}'
echo '{"type":"result","is_error":false,"result":"claude report","usage":{"input_tokens":3},"total_cost_usd":0.01}'
EOF
cat >"$tmp/bin/agent" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == models ]]; then printf 'gpt-5.6-sol\ngpt-5.6-sol-high\n'; exit 0; fi
cat >/dev/null
echo "$*" >"$MOCK_DIR/agent-args"
echo cursor >>work.txt
echo '{"type":"result","is_error":false,"result":"cursor report","session_id":"cursor-sid-1"}'
EOF
chmod +x "$tmp/bin/"*

export PATH="$tmp/bin:$PATH" MOCK_DIR="$tmp" TMPDIR="$tmp/runs" AGENT_DISPATCH_STATE="$tmp/state" CODEX_HOME="$tmp/codex-home"
unset AGENT_DISPATCH_WORKER CODEX_WORKER_MODEL CODEX_WORKER_EFFORT CLAUDE_WORKER_MODEL CLAUDE_WORKER_EFFORT \
  CURSOR_WORKER_MODEL CURSOR_WORKER_EFFORT CURSOR_WORKER_FORCE
echo "do the task" >"$tmp/task.md"
echo "fix finding 1" >"$tmp/feedback.md"

# A fresh repo with one committed file and one uncommitted user change.
new_repo() {
  local r="$tmp/$1"
  rm -rf "$r"
  git init -q "$r"
  git -C "$r" config user.email smoke@test
  git -C "$r" config user.name smoke
  git -C "$r" config core.autocrlf false
  echo base >"$r/work.txt"
  echo base >"$r/user.txt"
  git -C "$r" add -A && git -C "$r" commit -qm init
  echo "user edit" >>"$r/user.txt"
  echo "$r"
}

# Run the helper; sets $out, $code and $json (the run's summary.json).
run() {
  out=$(bash "$runner" "$@" 2>&1); code=$?
  local rd
  rd=$(sed -n 's/^run_dir: *//p' <<<"$out" | head -1)
  json="$rd/summary.json"
}
jqt() { jq -e "$1" "$json"; }

echo "syntax"
check "worker-run.sh parses" bash -n "$runner"
check "install.sh parses" bash -n "$here/install.sh"

echo "codex start"
repo=$(new_repo r1)
run start "$repo" "$tmp/task.md"
check "exit 0" test "$code" = 0
check "session id parsed" jqt '.session_id == "codex-sid-1"'
check "status completed" jqt '.status == "completed" and .worker == "codex"'
check "changed files = work.txt only" jqt '.changed_files == ["work.txt"]'
check "user change not flagged as touched" jqt '.user_files_touched == []'
check "commands counted" jqt '.commands.total == 2 and .commands.failed == 1'
check "usage parsed" jqt '.usage.input_tokens == 10'
check "head unchanged" jqt '.head_moved == false'
check "worker ran with AGENT_DISPATCH_WORKER=1" grep -qx "worker_env=1" "$tmp/codex-env"
check "workspace-write sandbox, no dangerous flags" bash -c 'grep -q -- "-s workspace-write" "$1" && ! grep -q danger "$1"' _ "$tmp/codex-args"
check "session state saved in state dir" test -f "$tmp/state/session-codex-sid-1.env"
check "lock released" test ! -e "$repo/.git/agent-dispatch.lock"

echo "codex resume"
run resume "$repo" codex-sid-1 "$tmp/feedback.md"
check "resume exit 0" test "$code" = 0
check "resume uses exec resume with the session" grep -q "exec resume .*codex-sid-1" "$tmp/codex-args"
check "worker's earlier edit not flagged as user change" jqt '.user_files_touched == []'

echo "claude start + resume (worker remembered)"
repo=$(new_repo r2)
run -w claude -m opus -e high start "$repo" "$tmp/task.md"
check "claude session id" jqt '.session_id == "claude-sid-1" and .model == "opus" and .effort == "high"'
check "claude command paired with result" jqt '.commands.total == 1 and .commands.failed == 0'
check "claude git writes denied, no bypass" bash -c 'grep -q "Bash(git commit \*)" "$1" && ! grep -qi bypass "$1"' _ "$tmp/claude-args"
run resume "$repo" claude-sid-1 "$tmp/feedback.md"
check "resume without -w reuses claude, model, effort" jqt '.worker == "claude" and .model == "opus" and .effort == "high"'
check "claude resume passes --resume" grep -q -- "--resume claude-sid-1" "$tmp/claude-args"

echo "cursor"
repo=$(new_repo r3)
run -w cursor -m gpt-5.6-sol -e high start "$repo" "$tmp/task.md"
check "cursor session id" jqt '.session_id == "cursor-sid-1"'
check "effort folded into listed model id" grep -q -- "--model gpt-5.6-sol-high" "$tmp/agent-args"
check "no --force by default" bash -c '! grep -q -- "--force" "$1"' _ "$tmp/agent-args"

echo "worker touches the user's uncommitted file"
repo=$(new_repo r4)
echo "user edit" >>"$repo/work.txt"
run start "$repo" "$tmp/task.md"
check "overlap reported" jqt '.user_files_touched == ["work.txt"]'
check "overlap warning printed" grep -q "had uncommitted user changes" <<<"$out"

echo "worker commits a new file (HEAD drift)"
repo=$(new_repo r5)
MOCK_NEWFILE=1 MOCK_COMMIT=1 run start "$repo" "$tmp/task.md"
check "head_moved true" jqt '.head_moved == true'
check "committed new file still listed" jqt '.changed_files | index("new.txt") != null'
check "commit recorded" jqt '.commits | length == 1'
check "HEAD warning printed" grep -q "WARNING: HEAD moved" <<<"$out"

echo "worker failure"
repo=$(new_repo r6)
MOCK_FAIL=1 run start "$repo" "$tmp/task.md"
check "worker exit code passed through" test "$code" = 1
check "status failed with error" jqt '.status == "failed" and .error == "boom"'
check "lock released after failure" test ! -e "$repo/.git/agent-dispatch.lock"

echo "repo lock"
repo=$(new_repo r7)
sleep 60 & live=$!
mkdir "$repo/.git/agent-dispatch.lock"
printf 'pid=%s\nwinpid=%s\nhost=%s\n' "$live" "$(cat /proc/$live/winpid 2>/dev/null)" "$(hostname)" \
  >"$repo/.git/agent-dispatch.lock/owner"
run start "$repo" "$tmp/task.md"
check "live lock -> exit 3" test "$code" = 3
check "busy message" grep -q "is busy" <<<"$out"
check "live lock kept" test -d "$repo/.git/agent-dispatch.lock"
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
printf 'pid=999999\nwinpid=\nhost=%s\n' "$(hostname)" >"$repo/.git/agent-dispatch.lock/owner"
run start "$repo" "$tmp/task.md"
check "stale lock reclaimed, run succeeds" test "$code" = 0
check "reclaim noted" grep -q "reclaiming stale lock" <<<"$out"
check "lock released" test ! -e "$repo/.git/agent-dispatch.lock"

echo "recursion guard"
repo=$(new_repo r8)
out=$(AGENT_DISPATCH_WORKER=1 bash "$runner" start "$repo" "$tmp/task.md" 2>&1); code=$?
check "refuses inside a worker" bash -c '[[ $1 == 2 ]] && grep -q "refusing to dispatch" <<<"$2"' _ "$code" "$out"

echo "usage errors"
out=$(bash "$runner" -w nope start "$repo" "$tmp/task.md" 2>&1); code=$?
check "unknown worker -> exit 2" test "$code" = 2
out=$(bash "$runner" start "$tmp" "$tmp/task.md" 2>&1); code=$?
check "non-git dir -> exit 2" test "$code" = 2

echo "install.sh"
home="$tmp/home"
mkdir -p "$home"
out=$(HOME="$home" CLAUDE_CONFIG_DIR= bash "$here/install.sh" --target all 2>&1); code=$?
check "install --target all" test "$code" = 0
for d in "$home/.claude/skills/agent-dispatch" "$home/.agents/skills/agent-dispatch"; do
  check "installed $d" test -f "$d/SKILL.md" -a -x "$d/scripts/worker-run.sh" -a -f "$d/references/review.md"
done
out=$(HOME="$home" CLAUDE_CONFIG_DIR= bash "$here/install.sh" --target agents 2>&1); code=$?
check "reinstall without --force refused" test "$code" = 1
out=$(HOME="$home" CLAUDE_CONFIG_DIR= bash "$here/install.sh" --target agents --force 2>&1); code=$?
check "reinstall with --force" test "$code" = 0

echo
echo "passed: $pass  failed: $fail"
[[ $fail == 0 ]]
