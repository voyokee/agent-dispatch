# agent-dispatch

An agent skill where **the agent session you are working in (Claude Code, Codex or Cursor) plans and reviews, and an external coding CLI implements**. The worker can be **OpenAI Codex CLI**, **Claude Code CLI** or **Cursor agent CLI**.

当前 IDE 里的 Agent 会话（Claude Code / Codex / Cursor）是 **Master**：负责理解需求、规划、定义验收标准和最终验收。用 `-w` 选的 CLI 是 **Worker**（Codex / Claude CLI / Cursor）：负责写代码、写测试和调试。Worker 的自我报告不算证据，Master 会自己检查真实的 `git diff` 并亲自跑验证。

```
需求 → Master：探索 / 规划 / 验收标准 → Worker：实现 / 测试
     → Master：检查 diff + 独立验证 → PASS 交付 / FAIL 反馈给同一个 Worker 会话修复（默认最多 2 轮）
PLAN → DISPATCH → VERIFY → ACCEPT | REPAIR | ESCALATE
```

## 特点

- **默认不启用**：只有你明确要求时才会调用 Worker，其他任务 Master 自己完成。
- **Master 可互换**：同一份 `SKILL.md` 装到 Claude Code（`~/.claude/skills`）或 Codex / Cursor（`~/.agents/skills`）都能用。
- **三种 Worker，统一接口**：`-w codex | claude | cursor`，每个都支持选择模型和推理强度。
- **修复轮次保留上下文**：修复时恢复同一个 Worker 会话（Codex `exec resume`，Claude / Cursor `--resume`）。
- **改动可追溯**：运行前后给工作区拍快照，精确列出 Worker 改了哪些文件。Worker 擅自 commit 时，提交里的文件也会列出来，并给出警告和提交列表；碰了你原本未提交的改动也会警告。脚本还会记录 Worker 执行过的命令。
- **结构化结果**：每次运行除了 `summary.txt` 还有 `summary.json`，方便 Master 读取。`status: completed` 只表示 Worker 进程正常结束，不代表验收通过。
- **一个工作区同时只有一个 Worker**：用 `<git dir>/agent-dispatch.lock` 互斥。另一个 Worker 正在写时返回退出码 3；持锁进程已经死掉的锁会被自动回收。
- **不会递归委派**：Worker 运行时带 `AGENT_DISPATCH_WORKER=1`，在这个环境里脚本拒绝再启动 Worker。
- **安全边界**：
  - Codex 只用 `workspace-write` 沙箱，不使用 `danger-full-access`；沙箱默认不联网。
  - Claude 不使用 `bypassPermissions`，只允许工具白名单（默认 `Read Edit Write Glob Grep Bash`），并禁止 `git commit / push / merge / rebase / reset / checkout / stash / clean / restore`。注意：`Bash` 在白名单内，因此 Claude Worker 可以运行任意 shell 命令，只是不能用上面列出的 git 写操作。
  - 不自动 commit、push、merge 或部署；Master 只有在你明确授权后才 commit / push。
  - 任务文件和日志都不进你的仓库。
  - 「Worker 不能 commit」是事后检测（HEAD drift 警告），不是权限隔离。真正的强制隔离需要受限环境和 git 凭证隔离，留到后续版本。

## 安装

前置条件：

- 一个作为 Master 的 Agent：[Claude Code](https://claude.com/claude-code)、Codex 或 Cursor
- `git`、`jq`、`bash`（Windows 上用 Git Bash）
- 至少一个 Worker（按需装，缺哪个那个 Worker 不可用）：
  - **codex**：[Codex CLI](https://developers.openai.com/codex)，并执行 `codex login`
  - **claude**：[Claude Code CLI](https://claude.com/claude-code)，即 `claude` 命令，并已登录
  - **cursor**：Cursor agent CLI（命令 `agent`），并已登录

```bash
git clone https://github.com/voyokee/codex-worker.git agent-dispatch   # upstream repo name; this fork is renamed agent-dispatch
cd agent-dispatch
./install.sh                   # Claude Code: ~/.claude/skills/agent-dispatch
./install.sh --target agents   # Codex / Cursor: ~/.agents/skills/agent-dispatch
./install.sh --target all      # both
```

已安装过时加 `--force` 覆盖。几个位置装的是同一份文件。

可选：把「默认不用外部 Worker」设为全局规则：
- Claude Code：把 [`examples/CLAUDE.md`](examples/CLAUDE.md) 加到 `~/.claude/CLAUDE.md`
- Codex：把 [`examples/AGENTS.md`](examples/AGENTS.md) 加到 `~/.codex/AGENTS.md`
- Cursor：把 [`examples/AGENTS.md`](examples/AGENTS.md) 的内容加到 User Rules

装好后**新开一个 Agent 会话**才会加载。

### 用 Codex / Cursor 做 Master 时注意

- Master 要通过 `bash` 调用脚本（Windows 上是 Git Bash）。
- 脚本要写仓库外的目录（`$TMPDIR/agent-dispatch` 和 `~/.local/state/agent-dispatch`），Worker CLI 也要联网访问模型服务。如果 Master 自己的沙箱拦住了，需要为这条命令申请权限。Skill 规定 Master 不能自己切到不受限模式。

## 使用

在一个 git 仓库里，明确要求使用某个 Worker：

```
/agent-dispatch 给用户列表加分页，每页 20 条，带测试
/agent-dispatch -w claude 给用户列表加分页
```

或者用自然语言：「这个功能让 codex 做」「用 claude 实现 X」「交给 cursor」「use cursor to …」。没指定 Worker 时默认用 codex。

每个任务都需要单独要求，上一个任务用了某个 Worker 不代表下一个也会用。

如果想彻底禁止 Agent 自行调用，只允许 `/agent-dispatch` 触发，可以在 `SKILL.md` 的 frontmatter 里加一行 `disable-model-invocation: true`（Claude Code 支持；其他客户端是否支持以各自文档为准）。

### 选择 Worker、模型和推理强度

在请求里直接写就行，不写则使用各 Worker 的默认设置：

```
/agent-dispatch model=gpt-5.6-sol effort=high 给用户列表加分页
让 claude 用 opus、max 实现 X
让 cursor 用 gpt-5.2、high 实现 X
codex 现在有哪些模型？
```

- Master 会把模糊的名字对照对应 Worker 的模型列表解析；对不上或者有歧义时会先问你。
- 修复轮自动沿用第一次运行的 Worker、模型和推理强度，除非你要求切换。
- Master 不会自己挑 Worker、模型或强度。

查看各 Worker 可用的模型（`<skill_dir>` 是安装位置）：

```bash
bash <skill_dir>/scripts/worker-run.sh -w codex models    # 读取 Codex 本地的模型缓存
bash <skill_dir>/scripts/worker-run.sh -w claude models   # 别名 + 模型 ID + 强度档位
bash <skill_dir>/scripts/worker-run.sh -w cursor models   # 调用 agent models
```

各 Worker 的推理强度处理方式不同：

| Worker | 模型 | 推理强度 |
|---|---|---|
| codex | `-m`，列表见 `models` | `-e low/medium/high/xhigh/max`（具体支持哪些取决于模型） |
| claude | `-m opus / sonnet / haiku` 或完整模型 ID | `-e low/medium/high/xhigh/max`（`--effort`） |
| cursor | `-m <model>`，列表见 `models` | Cursor 没有独立的强度参数：`-m gpt-5.6-sol -e high` 会解析成 `gpt-5.6-sol-high`（在 `agent models` 里查找，`xhigh` 也会尝试 `extra-high`）；查不到时按 `model[effort=high]` 传 |

### 可选环境变量

| 变量 | 作用 |
|---|---|
| `CODEX_WORKER_MODEL` / `CODEX_WORKER_EFFORT` | codex 默认模型 / 推理强度（优先级高于 `config.toml`，低于请求里指定的值） |
| `CLAUDE_WORKER_MODEL` / `CLAUDE_WORKER_EFFORT` | claude 默认模型 / 推理强度 |
| `CURSOR_WORKER_MODEL` / `CURSOR_WORKER_EFFORT` | cursor 默认模型 / 推理强度（强度会拼进模型名） |
| `CODEX_WORKER_NETWORK=1` | 允许 Codex 沙箱联网（Skill 规定开启前要先征得你同意） |
| `CLAUDE_WORKER_TOOLS="Read Edit Write Glob Grep Bash"` | Claude Worker 的工具白名单 |
| `CURSOR_WORKER_FORCE=1` | 允许 Cursor 执行 shell 命令（`--force`，Windows 上无沙箱，开启前要先征得你同意） |
| `AGENT_DISPATCH_STATE` | 会话状态目录（默认 `$XDG_STATE_HOME/agent-dispatch`，否则 `~/.local/state/agent-dispatch`） |

## 运行产物

| 位置 | 内容 |
|---|---|
| `$TMPDIR/agent-dispatch/<repo>-<时间>-<pid>/` | 每次运行的证据：`prompt.md`、`events.jsonl`、`stderr.log`、`last-message.md`、`commands.tsv`、`changed-files.txt`、`commits.txt`、`summary.txt`、`summary.json`；Master 验收后写入 `review.md`（和 `feedback.md`） |
| `~/.local/state/agent-dispatch/` | 长期状态：每个会话的 Worker / 模型 / 强度（`session-*.env`）和首轮开始前你已有的未提交改动（`baseline-*.tsv`），修复轮依赖它们 |
| `<git dir>/agent-dispatch.lock` | 运行期间的工作区锁，运行结束自动删除 |

退出码：Worker 自己的退出码；`2` 参数或环境错误；`3` 工作区被另一个正在运行的 Worker 锁住。

`summary.json` 示例：

```json
{
  "run_id": "myrepo-20261030-120007-1634",
  "mode": "start",
  "worker": "codex",
  "model": "gpt-5.6-sol",
  "effort": "low",
  "session_id": "provider-session-id",
  "status": "completed",
  "exit_code": 0,
  "elapsed_s": 95,
  "error": null,
  "workspace": "/path/to/repo",
  "head_before": "abc123...",
  "head_after": "abc123...",
  "head_moved": false,
  "changed_files": ["src/api.py", "tests/test_api.py"],
  "user_files_touched": [],
  "commits": [],
  "commands": {"total": 4, "failed": 0},
  "usage": {"input_tokens": 12345, "output_tokens": 678},
  "evidence": {"prompt": "...", "events": "...", "report": "...", "commands": "...", "stderr": "...", "summary": "..."}
}
```

## 文件结构

```
skills/agent-dispatch/
├── SKILL.md                    # 通用 Master 流程与硬性规则
├── scripts/worker-run.sh       # 调用 codex / claude / cursor 并记录改动
└── references/
    ├── task-template.md        # 任务规格模板 + 修复反馈模板
    └── review.md               # 验收、修复反馈、评审记录规则
examples/CLAUDE.md              # Claude Code 可选全局规则
examples/AGENTS.md              # Codex / Cursor 可选全局规则
tests/smoke.sh                  # 用假 CLI 的冒烟测试（不需要账号和额度）
install.sh
```

也可以单独使用辅助脚本：

```bash
skills/agent-dispatch/scripts/worker-run.sh [-w codex|claude|cursor] [-m model] [-e effort] start  <repo_dir> <task_file>
skills/agent-dispatch/scripts/worker-run.sh [-w ...] [-m model] [-e effort] resume <repo_dir> <session_id> <feedback_file>
skills/agent-dispatch/scripts/worker-run.sh [-w ...] models
```

## 测试

```bash
bash tests/smoke.sh
```

用假的 `codex` / `claude` / `agent` 命令覆盖：三种 Worker 的 start / resume、会话 ID 解析、模型与强度解析、改动检测、触碰用户改动的警告、Worker 自行 commit（含新文件）、Worker 失败、工作区锁（占用中 / 死锁回收）、递归保护、参数错误和 `install.sh`。不调用真实模型。

## 测试状态

- **codex**：在 Codex CLI 0.153 上端到端测试通过（`-m gpt-5.6-sol -e low`）。注意：`~/.codex/config.toml` 里的默认模型在 ChatGPT 账号下可能不可用，报 `model_not_found`，这时需要用 `-m` 指定一个账号可用的模型。
- **claude**：在 Claude Code CLI 2.1.296 上端到端测试通过（`start` 与 `resume` 修复轮）。
- **cursor**：在 Cursor agent CLI 2026.10.22 上端到端测试通过（`start` 与 `resume`，`-m gpt-5.4-mini -e low`）。在 Windows 上 Cursor 不支持沙箱（`--sandbox enabled` 仅 macOS/Linux），所以默认**不加 `--force`**：改文件可以，但 shell 命令会被拒绝。需要让 Cursor 跑测试/构建时，设 `CURSOR_WORKER_FORCE=1`（等于不受限地执行命令，Skill 规定要先征得你同意）。
- **Master**：Claude Code 作为 Master 已使用。Codex 和 Cursor 作为 Master（从 `~/.agents/skills` 发现并执行 Skill）尚未实测。

## License

MIT
