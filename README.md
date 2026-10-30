# agent-dispatch

An agent skill where **the agent session you are working in (Claude Code, Codex or Cursor) plans and reviews, and an external coding CLI implements**. The worker can be **OpenAI Codex CLI**, **Claude Code CLI** or **Cursor agent CLI**.

当前 IDE 里的 Agent 会话（Claude Code / Codex / Cursor）是 **Master**：负责理解需求、规划、定义验收标准和最终验收。用 `-w` 选的 CLI 是 **Worker**（Codex / Claude CLI / Cursor）：负责写代码、写测试和调试。Worker 的自我报告不算证据，Master 会自己检查真实的 `git diff` 并亲自跑验证。

## 为什么需要它（Problem Statement）

很多人同时在用好几个 Coding Agent：Claude Code、Codex、Cursor。它们各有长处，但差别很大：

- **能力和模型不同**：擅长的任务不一样，可选的模型和推理强度也不一样。
- **额度分开计算**：一个工具的额度用完了，或者某个模型在当前账号或 CLI 版本下不可用，就想把活交给另一个。
- **执行环境与数据合规不同**：Codex 有 `workspace-write` 沙箱；Claude Code 靠权限模式和工具白名单；Cursor 在 Windows 上没有沙箱；公司仓库可能只允许交给企业账号。
- **接口与用量统计各不相同**：启动方式、会话恢复、输出格式、Token 缓存统计口径、退出码都不一样。

问题在于，这些工具之间**没有统一的任务交付、额度感知、用量归因和验收机制**：

- 换一个工具干活，就要重新写一遍任务说明，重新学一遍它的会话和输出格式。
- Worker 说「测试都过了」，但这是它的自我报告，不是证据。
- 一个真实工程任务往往包含首次执行（`start`）和 1～2 次修复轮（`resume`），按单次进程运行记账会把 3 次运行误算成 3 个任务，或重复计算缓存 Token。

agent-dispatch 把这些统一起来：不管谁当 Master、谁当 Worker，都用**同一套 Task Spec、建议式额度路由（Advisory Router）、统一的 Usage Schema、按任务归并的持久账本（Task Ledger），以及同一个独立验收流程**。

它**不做**的事：它不是独立的编排服务，没有 Python/Node.js 常驻进程、MCP Server 或数据库；路由只提供确定性建议（Advisory），不会违背用户显式指定偷偷换 Worker，也不会并行跑多个 Worker。

## 架构（Architecture）

```
                         Master Agent
                 Claude Code / Codex / Cursor
            Planning · Task Specification · Review
                              │
                              ├─► dispatchctl.sh (Quota · Policy · Recommend · Review · Stats)
                              ↓
                 worker-run.sh (Skill-driven delegation)
       ┌──────────────┬──────────────┬──────────────┐
       │  Codex CLI   │ Claude Code  │ Cursor Agent │
       └──────────────┴──────────────┴──────────────┘
                              │
                              ↓  Diff · Test Results · Normalized Usage · Task Ledger
                      Master Verification
                   PASS / FAIL (Repair) / ESCALATE
```

## 特点

- **默认不启用**：只有你明确要求时才会调用 Worker，其他任务 Master 自己完成。
- **显式输入优先 + 默认配置分级回退**：
  - 指定了 Worker / 模型 / 推理强度时直接使用并回显来源（`explicit`），绝不偷偷篡改用户的显式选择。
  - 未指定时自动按优先级回退（Worker：`Repository Policy → Quota 状态 → 任务偏好 → 默认顺序 codex → claude → cursor`；Model/Effort：`explicit → session → 环境变量 → policy.json → CLI config.toml → CLI default`），并在输出中明确回显最终生效值与配置来源。
- **Quota 状态与 TTL 自动过期**：支持 `available`、`limited`、`exhausted`、`unknown` 四种状态，超过 `ttl_seconds` 自动回退为 `unknown`，避免昨天耗尽的额度今天重置后仍被锁死；支持从 Claude `rate_limit_event` 自动观测限额。
- **Repository Policy 仓库白名单**：可按仓库路径（精确或前缀）限制允许使用的 Worker（例如企业代码只允许 `cursor`），在 `recommend` 和 `worker-run.sh` 两侧双重拦截。
- **统一 Usage Schema（防缓存重复计数）**：通过独立的 `normalize-usage.jq` 将三家 CLI 的用量统一为 `input_uncached_tokens`、`cache_read_tokens`、`cache_write_tokens`、`output_tokens`、`reasoning_tokens`、`total_tokens`、`cost_usd`；消除 Codex `input_tokens` 含缓存的重复计数，以及 Claude `--resume` 会话累计费用的重复计入。
- **Task Ledger 与机器可读 Verdict**：`start` 生成 `task_id`，同一会话的 `resume` 共享该 `task_id` 并递增 `round`。Master 独立验证后通过 `dispatchctl.sh review` 提交 `PASS / FAIL / ESCALATE`，`dispatchctl.sh stats` 按任务维度汇总首轮通过率、修复轮数、耗时、Token 与费用覆盖率（`missing_cost_runs`）。
- **Claude Worker 冷启动减税**：默认开启 `CLAUDE_WORKER_SLIM=1`（传入 `--disable-slash-commands --strict-mcp-config`），避免无头 Worker 进程重复加载宿主机数十个全局 Skill 和外部 MCP 插件，大幅削减首轮固定上下文税。
- **安全边界与状态加固**：
  - 会话状态采用 SHA-256 哈希命名的 JSON 文件（`sessions/<hash>.json`），彻底移除 `source session-*.env`；旧 `.env` 仅通过严格的非执行解析器迁移，拒绝任何命令注入和路径穿越。
  - 状态与运行目录统一启用 `umask 077`（POSIX `0700`/`0600`）、防符号链接跳转检查、临时文件原子替换及 `config.lock` 并发锁。
  - Codex 只用 `workspace-write` 沙箱；Claude 禁止危险跳过权限并禁用 git 写操作；同一个工作区单 Writer 锁（退出码 3）；`AGENT_DISPATCH_WORKER=1` 防递归派发。

## 安装

前置条件：

- 一个作为 Master 的 Agent：[Claude Code](https://claude.com/claude-code)、Codex 或 Cursor
- `git`、`jq`、`bash`（Windows 上用 Git Bash）
- 至少一个 Worker（按需装，缺哪个那个 Worker 不可用）：
  - **codex**：[Codex CLI](https://developers.openai.com/codex)，并执行 `codex login`
  - **claude**：[Claude Code CLI](https://claude.com/claude-code)，即 `claude` 命令，并已登录
  - **cursor**：Cursor agent CLI（命令 `agent`），并已登录

```bash
git clone https://github.com/voyokee/agent-dispatch.git
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

## 使用

### 1. 派发任务与模型优先级回退

在一个 git 仓库里，明确要求使用 Worker：

```text
/agent-dispatch 给用户列表加分页，每页 20 条，带测试
/agent-dispatch -w claude model=opus effort=high 给用户列表加分页
让 cursor 用 gpt-5.4-mini、low 实现 X
```

- **显式指定时**：直接按你指定的 Worker、模型和推理强度执行，并在 `summary.txt` 回显 `(explicit)`。
- **未指定时**：Master 先调 `dispatchctl.sh recommend` 获取推荐 Worker，模型与强度按以下优先级自动回退并显示来源：
  1. 命令行显式参数 `-m` / `-e`（`explicit`）
  2. 修复轮继承的首轮会话配置（`session`）
  3. 环境变量 `<WORKER>_WORKER_MODEL` / `<WORKER>_WORKER_EFFORT`（`env`）
  4. `policy.json` 中的 `worker_defaults`（`policy.json`）
  5. CLI 本地配置如 `~/.codex/config.toml`（`config default`）
  6. CLI 内置默认（`CLI default`）

查看各 Worker 可用的模型（`<skill_dir>` 是安装位置）：

```bash
bash <skill_dir>/scripts/worker-run.sh -w codex models    # 读取 Codex 本地的模型缓存
bash <skill_dir>/scripts/worker-run.sh -w claude models   # 别名 + 模型 ID + 强度档位
bash <skill_dir>/scripts/worker-run.sh -w cursor models   # 调用 agent models
```

### 2. Quota 状态、Repository Policy 与建议式路由（`dispatchctl.sh`）

```bash
# 查询三个 Provider 的额度状态（含 TTL 过期自动回退计算）
bash <skill_dir>/scripts/dispatchctl.sh quota show --json

# 手动设置额度状态与有效期（分钟）
bash <skill_dir>/scripts/dispatchctl.sh quota set codex limited \
  --ttl-min 60 \
  --reason "5h quota almost exhausted"

# 恢复为未知状态
bash <skill_dir>/scripts/dispatchctl.sh quota set codex unknown

# 配置仓库级允许的 Worker 与默认模型（如公司项目只允许 cursor）
bash <skill_dir>/scripts/dispatchctl.sh policy set \
  --repo /path/to/corp-repo \
  --allow cursor \
  --default-model cursor=gpt-5.6-sol-high

# 获取路由推荐（纯计算，绝不自动启动 Worker）
bash <skill_dir>/scripts/dispatchctl.sh recommend \
  --repo . \
  --task-type implementation \
  --json
```

### 3. 提交验收 Verdict 与查看任务级统计

```bash
# Master 完成独立验证并写好 review.md 后，提交结构化判定（PASS | FAIL | ESCALATE）
bash <skill_dir>/scripts/dispatchctl.sh review \
  --run "$run_dir" \
  --verdict PASS \
  --evidence "$run_dir/review.md"

# 查看最近 30 天的任务级汇总统计（按 Task 创建时间归并所有 Repair 轮次）
bash <skill_dir>/scripts/dispatchctl.sh stats --last 30d --json
bash <skill_dir>/scripts/dispatchctl.sh stats --worker codex --json
```

### 可选环境变量

| 变量 | 作用 |
|---|---|
| `CODEX_WORKER_MODEL` / `CODEX_WORKER_EFFORT` | codex 默认模型 / 推理强度（优先级高于 `policy.json` 与 `config.toml`，低于显式 `-m`/`-e`） |
| `CLAUDE_WORKER_MODEL` / `CLAUDE_WORKER_EFFORT` | claude 默认模型 / 推理强度 |
| `CURSOR_WORKER_MODEL` / `CURSOR_WORKER_EFFORT` | cursor 默认模型 / 推理强度（强度会拼进模型名） |
| `CLAUDE_WORKER_SLIM=0\|1` | 默认为 `1`（禁用全局 Skill 与外部 MCP 以降低冷启动 Token 税）；设为 `0` 恢复完整加载 |
| `CODEX_WORKER_NETWORK=1` | 允许 Codex 沙箱联网（开启前须征得用户同意） |
| `CLAUDE_WORKER_TOOLS="Read Edit Write Glob Grep Bash"` | Claude Worker 的工具白名单 |
| `CURSOR_WORKER_FORCE=1` | 允许 Cursor 执行 shell 命令（`--force`，Windows 上无沙箱，开启前须征得用户同意） |
| `AGENT_DISPATCH_STATE` | 持久状态目录（默认 `$XDG_STATE_HOME/agent-dispatch`，否则 `~/.local/state/agent-dispatch`） |

## 运行产物与日志保留说明

| 位置 | 权限 (POSIX) | 内容与保留策略 |
|---|---|---|
| `$TMPDIR/agent-dispatch/<repo>-<时间>-<pid>/` | `0700` / `0600` | 每次运行的原始证据：`prompt.md`、`events.jsonl`、`stderr.log`、`last-message.md`、`commands.tsv`、`changed-files.txt`、`commits.txt`、`summary.txt`、`summary.json`、`review.md`、`review.json`。**注意**：原始日志可能包含代码片段或命令输出，不会自动删除以免破坏进行中的会话证据；无需保留时可手动清理 `rm -rf "${TMPDIR:-/tmp}/agent-dispatch"`。 |
| `~/.local/state/agent-dispatch/quota.json` | `0600` | 三个 Provider 的额度状态、观测时间戳与 TTL |
| `~/.local/state/agent-dispatch/policy.json` | `0600` | 仓库白名单（`allowed_workers`）、任务类型偏好与默认模型配置 |
| `~/.local/state/agent-dispatch/sessions/` | `0700` / `0600` | SHA-256 命名的会话状态 JSON（`<hash>.json`）与首轮前的用户未提交基线（`baseline-<hash>.tsv`） |
| `~/.local/state/agent-dispatch/records/<task-id>/` | `0700` / `0600` | 持久任务账本：`<run-id>.json`（仅存结构化元数据、标准化 Usage 和证据路径，不存完整 Prompt 与源码）及 `<run-id>.review.json` |
| `<git dir>/agent-dispatch.lock` | — | 运行期间的工作区单 Writer 锁，结束或中断时自动释放 |

`summary.json` 示例：

```json
{
  "schema_version": 1,
  "task_id": "task-20261030-120007-1634",
  "run_id": "myrepo-20261030-120007-1634",
  "round": 0,
  "mode": "start",
  "worker": "codex",
  "model": "gpt-5.6-sol",
  "effort": "low",
  "resolution": {
    "worker_source": "explicit",
    "model_source": "explicit",
    "effort_source": "config default"
  },
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
  "usage": {
    "schema_version": 1,
    "model_requested": "gpt-5.6-sol",
    "model_resolved": null,
    "input_uncached_tokens": 12066,
    "input_tokens": 12066,
    "cache_read_tokens": 77184,
    "cache_write_tokens": 0,
    "output_tokens": 560,
    "reasoning_tokens": 30,
    "total_tokens": 89810,
    "cost_usd": null,
    "cost_kind": null,
    "source": "cli_result"
  },
  "evidence": {"prompt": "...", "events": "...", "report": "...", "commands": "...", "stderr": "...", "summary": "..."}
}
```

## 文件结构

```
agent-dispatch/
├── README.md
├── install.sh
├── skills/agent-dispatch/
│   ├── SKILL.md                    # Master 流程、显式/默认优先级与硬性规则
│   ├── scripts/
│   │   ├── worker-run.sh           # 执行器：调用 CLI、安全会话 JSON、改动快照与持久记录
│   │   ├── dispatchctl.sh          # 控制器：quota / policy / recommend / review / stats
│   │   └── normalize-usage.jq      # 三家 CLI Usage 归一化过滤器
│   └── references/
│       ├── task-template.md        # 任务规格模板 + 修复反馈模板
│       └── review.md               # 独立验收、结构化 Verdict 提交与修复规则
├── examples/
│   ├── CLAUDE.md                   # Claude Code 可选全局规则
│   └── AGENTS.md                   # Codex / Cursor 可选全局规则
└── tests/
    ├── smoke.sh                    # 基础执行与向后兼容冒烟测试
    ├── v02.sh                      # Quota / Recommend / Usage / Ledger / 安全回归测试
    └── fixtures/                   # 真实 CLI 事件流测试数据
        ├── codex-events.jsonl
        ├── claude-events.jsonl
        └── cursor-result.json
```

## 自动化测试

```bash
bash tests/smoke.sh
bash tests/v02.sh
```

全部使用假 CLI 与真实事件 Fixture 运行，不消耗真实订阅额度。覆盖：
- `tests/smoke.sh`：三种 Worker 的 `start / resume / models`、改动检测、用户改动重叠警告、Worker 擅自 commit、进程失败、工作区锁与死锁回收、递归保护、`install.sh`。
- `tests/v02.sh`：Quota 四状态与 TTL 过期回退（`Q01–Q04`）、Advisory 路由与显式覆盖/仓库白名单拦截（`R01–R05`）、三家 Usage 归一与防重复计数（`U01–U05`）、Task Ledger 跨轮次归并、幂等 Review 与缺失费用覆盖率统计（`T01–T05`）、恶意 `.env` 代码注入防御、路径穿越拦截、信号中断证据保留与并发写锁（`S01–S05`）、向后兼容与安装校验（`B01–B03`）。

## 常见问题

### Codex 报 `model_not_found`：「The '<model>' model is not supported when using Codex with a ChatGPT account」

最常见的原因是**本机 Codex CLI 版本太旧**，不是账号没有这个模型，也和 Master 会话本身用的是什么模型无关（Worker 是独立启动的 Codex 进程，`-m` 指定的就是 Worker 的模型）。

排查步骤：
1. 查看本机版本和模型缓存：`codex --version` 及 `bash <skill_dir>/scripts/worker-run.sh -w codex models`。
2. 升级 Codex CLI（例如 `npm i -g @openai/codex@latest`）。

## License

MIT
