# agent-dispatch

An agent skill where **the agent session you are working in (Claude Code, Codex or Cursor) plans and reviews, and an external coding CLI implements**. The worker can be **OpenAI Codex CLI**, **Claude Code CLI** or **Cursor agent CLI**.

当前 IDE 里的 Agent 会话（Claude Code / Codex / Cursor）是 **Master**：负责理解需求、规划、定义验收标准和最终验收。用 `-w` 选的 CLI 是 **Worker**（Codex / Claude CLI / Cursor）：负责写代码、写测试和调试。Worker 的自我报告不算证据，Master 会自己检查真实的 `git diff` 并亲自跑验证。

## 为什么需要它（Problem Statement）

很多人同时在用好几个 Coding Agent：Claude Code、Codex、Cursor。它们各有长处，但差别很大：

- **能力和模型不同**：擅长的任务不一样，可选的模型和推理强度也不一样。
- **额度分开计算**：一个工具的额度用完了，或者某个模型在当前账号或 CLI 版本下不可用，就想把活交给另一个。
- **执行环境不同**：Codex 有 `workspace-write` 沙箱；Claude Code 靠权限模式和工具白名单；Cursor 在 Windows 上没有沙箱。
- **接口各不相同**：启动方式、会话恢复、输出格式、退出码都不一样。

问题在于，这些工具之间**没有统一的任务交付和验收机制**：

- 换一个工具干活，就要重新写一遍任务说明，重新学一遍它的会话和输出格式。
- Worker 说「测试都过了」，但这是它的自我报告，不是证据。
- 让一个 Agent 去调另一个 Agent 时，没人保证它只改了该改的文件、没碰你没提交的改动、没自己 commit，也没人保证两个 Agent 不会同时写同一个工作区。

agent-dispatch 把这些统一起来：不管谁当 Master、谁当 Worker，都用**同一套 Task Spec、同一种执行证据、同一个验收与修复流程**，最终验收权始终在 Master 手里。

它**不做**的事：它不是独立的编排服务，没有 MCP Server、守护进程或数据库；不会自动选择 Worker，也不会并行跑多个 Worker。这些留到后续版本。

## 架构（Architecture）

```
                         Master Agent
                 Claude Code / Codex / Cursor
            Planning · Task Specification · Review
                              │
                              ↓  Skill-driven delegation
       ┌──────────────┬──────────────┬──────────────┐
       │  Codex CLI   │ Claude Code  │ Cursor Agent │
       └──────────────┴──────────────┴──────────────┘
                              │
                              ↓  Diff · Test Results · Execution Evidence
                      Master Verification
                   Accept / Repair / Escalate
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
  - 这些约束的边界见「证据与限制」。

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

## 证据与限制（Evidence & Limitations）

这一节只写真正跑过的东西，没跑过的明确标为未验证。

### 自动化测试

```bash
bash tests/smoke.sh
```

用假的 `codex` / `claude` / `agent` 命令跑，不需要账号，也不消耗额度。覆盖三种 Worker 的 start / resume、会话 ID 解析、模型与强度解析、改动检测、触碰用户改动的警告、Worker 自行 commit（含新文件）、Worker 失败、工作区锁（占用中 / 死锁回收）、递归保护、参数错误和 `install.sh`。

当前结果：**48 / 48 通过**（Windows 11，Git Bash）。

为了确认这些测试真的能抓到问题，做过三次「故意改坏」检查。每次只破坏一处逻辑，对应的测试都失败了：

| 故意破坏的逻辑 | 失败的测试 |
|---|---|
| 不把 Worker 提交里的文件算进改动列表 | `committed new file still listed` |
| 永远不回收死掉进程的锁 | `stale lock reclaimed, run succeeds` 等 4 项 |
| 关掉递归保护 | `refuses inside a worker` |

### 真实 CLI 端到端运行

2026-10-30，Windows 11 + Git Bash，Claude Code 作为 Master。每个 Worker 在独立的临时仓库里做同一个小任务（给 `calc.py` 加 `add` 函数），然后跑一轮修复（要求补 docstring）。每轮结束后，Master 自己检查 `git diff`、运行 `git diff --check`，并实际执行代码验证。

| Worker | 版本 | 模型 / 强度 | 首次执行 | 修复轮（resume） | Master 独立验证 |
|---|---|---|---|---|---|
| codex | Codex CLI 0.153.0 | `gpt-5.6-sol` / low | 73 秒，exit 0 | 71 秒，沿用同一会话 | 只改了 `calc.py`；`add(2,3)=5`；`mul` 没变；docstring 已加 |
| claude | Claude Code 2.1.296 | `haiku` / low | 46 秒，exit 0 | 41 秒 | 同上 |
| cursor | Cursor agent 2026.10.22 | `gpt-5.4-mini` / low | 67 秒，exit 0 | 51 秒 | 同上 |

三个修复轮都自动沿用了首次运行的 Worker、模型和强度，也没有把 Worker 上一轮的改动误报为「用户改动」。

一次真实运行的输出（codex 首次执行；路径已缩短）：

```
== worker-run ==
mode:        start
worker:      codex
model:       gpt-5.6-sol
effort:      low
session_id:  01a18b0f-9433-7a61-ada4-91d6c68afb95
exit_code:   0  (elapsed 73s)

Files changed during this run (1):
  calc.py

Commands run: 3 (non-zero exits: 1) -> <run_dir>/commands.tsv
```

这里那条「非零退出」是 Worker 先试了 `python`，本机没有这个命令；它随后改用 `py` 成功了。`commands.tsv` 把这个过程原样记了下来，Master 验收时能看到。

### 失败与恢复场景

| 场景 | 行为 | 怎么验证的 |
|---|---|---|
| Worker 运行时，另一个 Master 对同一仓库派发 | 第二个立即退出，退出码 3，并打印锁的持有者（进程号、Worker、开始时间） | 真实 CLI：codex 运行中再启动 claude；以及冒烟测试 |
| 上次运行被强杀，留下锁 | 持锁进程已不存在时自动回收，并提示 `reclaiming stale lock` | 冒烟测试 |
| Worker 失败（如模型报错） | 透传 Worker 的退出码；`summary.json` 为 `status: failed` 并带错误信息；锁照常释放 | 冒烟测试 |
| Worker 擅自 commit（包括新建文件后 commit） | 警告 HEAD 移动并列出提交；提交里的文件也算进改动列表 | 冒烟测试 |
| Worker 改了你原本未提交的文件 | 警告并列出这些文件，`summary.json` 的 `user_files_touched` | 冒烟测试 |
| 修复轮 | resume 同一会话；以首轮开始前的状态为基准，不会把 Worker 自己上一轮的改动当成用户改动 | 真实 CLI（三种 Worker）+ 冒烟测试 |
| Worker 里再调用 agent-dispatch | 拒绝执行，退出码 2 | 冒烟测试 |
| Codex 报 `model_not_found` | 不是脚本问题，多半是 CLI 版本太旧 | 真实 CLI 对比 0.153.0 与 0.166.0，见「常见问题」 |

### 已知限制

- **「Worker 不能 commit / push」不是强制安全隔离。** Codex 靠沙箱，Claude 靠工具白名单和 git 命令的拒绝规则，Cursor 不加 `--force` 时不能执行命令。但没有一种是凭证级隔离。HEAD drift 检测是**事后发现**，不是事前阻止，而且查不到 push。要真正隔离，需要独立 worktree / 容器和受限的 git 凭证，留到后续版本。
- **Claude Worker 可以运行任意 shell 命令**：`Bash` 在默认白名单里，只是禁止了列出的那几种 git 写操作。
- **Cursor 在 Windows 上没有沙箱**（`--sandbox enabled` 只在 macOS / Linux 生效），所以默认不加 `--force`。这时它能改文件，但不能跑测试。设 `CURSOR_WORKER_FORCE=1` 等于让它不受限地执行命令。Cursor 的 JSON 输出里也没有命令记录，所以 `commands.tsv` 一直是空的。
- **改动检测按文件**：能发现 Worker 碰了你已改过的文件，但分不出同一个文件里哪些行是你改的、哪些是 Worker 改的。这需要 Master 看 diff 判断。
- **锁只管 agent-dispatch 自己**：它挡得住第二个 Worker，挡不住你或 IDE 同时手动编辑。锁靠进程号判断死活；进程号被复用时会当成「仍在占用」（宁可误报占用，也不误删），需要手动删锁目录。
- **验收质量取决于 Master**：最终判定是 Master（一个 LLM）跑验证后做出的，不是确定性的评测器。
- **证据在临时目录**：每次运行的证据和评审记录放在 `$TMPDIR/agent-dispatch`，系统清理临时目录后会丢失。修复轮依赖的会话状态在 `~/.local/state`，不受影响。
- **未验证**：
  - Codex 和 Cursor 作为 Master：能否从 `~/.agents/skills` 发现 Skill，它们的沙箱是否允许运行执行器。
  - macOS 自带的 bash 3.2：只做了代码层面的检查，没在真机上跑。
  - Linux / macOS 上 Cursor 的 `--sandbox enabled` 路径。
- **v0.2 不做**：自动选择 Worker、额度感知、并行 Worker、根据评审结果自动演进 Skill。

## 常见问题

### Codex 报 `model_not_found`：「The '<model>' model is not supported when using Codex with a ChatGPT account」

最常见的原因是**本机 Codex CLI 版本太旧**，不是账号没有这个模型，也和 Master 会话本身用的是什么模型无关（Worker 是独立启动的 Codex 进程，`-m` 指定的就是 Worker 的模型）。

ChatGPT 账号下，Codex 服务端会按客户端版本下发可用模型。新模型只对较新的 CLI 开放，旧 CLI 请求这些模型时，服务端直接返回 400 `model_not_found`。

实测（2026-10-30，同一个 ChatGPT 账号）：

| 模型 | Codex CLI 0.153.0 | Codex CLI 0.166.0 |
|---|---|---|
| `gpt-6-astra` | ✅ | — |
| `gpt-6-luna` | ❌ `model_not_found` | ✅ |
| `gpt-6.1-terra` | ❌ `model_not_found` | ✅ |

排查步骤：

1. 看本机版本和服务端给这个版本下发的模型：
   ```bash
   codex --version
   bash <skill_dir>/scripts/worker-run.sh -w codex models   # 读取 ~/.codex/models_cache.json
   ```
   `models_cache.json` 里的 `client_version` 就是拉取列表时的 CLI 版本。想用的模型不在列表里，基本就是版本问题。
2. 看最新版本：`npm view @openai/codex version`。
3. 不升级也可以先验证：`npx -y @openai/codex@<最新版本> exec --skip-git-repo-check -s read-only -m <model> -` 能跑通，就说明升级 CLI 能解决。
4. 升级 Codex CLI（用你当初的安装方式，例如 `npm i -g @openai/codex@latest`，或重新运行官方安装包）。
5. 如果 `~/.codex/config.toml` 里的默认 `model` 是新版才支持的模型，旧 CLI 不带 `-m` 时也会报这个错。这时可以升级，或者用 `-m` 换一个列表里有的模型。

如果升级到最新版、模型仍然不在列表里，才是账号或套餐没有开放这个模型。

## License

MIT
