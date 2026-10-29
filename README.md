# codex-worker

A Claude Code skill where **Claude Code plans and reviews, and OpenAI Codex CLI implements**.

Claude Code 负责理解需求、规划、定义验收标准和最终验收；Codex CLI 作为 Worker 负责写代码、写测试和调试。Codex 的自我报告不算证据，Claude 会自己检查真实的 `git diff` 并亲自跑验证。

```
需求 → Claude：探索 / 规划 / 验收标准 → Codex：实现 / 测试
     → Claude：检查 diff + 独立验证 → PASS 交付 / FAIL 反馈给同一个 Codex 会话修复（默认最多 2 轮）
```

## 特点

- **默认不启用**：只有你明确要求时才会调用 Codex，其他任务 Claude 自己完成。
- **基于当前 Codex CLI**：使用 `codex exec`，不依赖已移除的 `codex mcp-server`。
- **修复轮次保留上下文**：修复时用 `codex exec resume <session_id>` 继续同一个 Codex 会话。
- **改动可追溯**：辅助脚本在运行前后给工作区拍快照，精确列出 Codex 改了哪些文件。如果 Codex 碰了你原本未提交的改动，或者擅自 commit，都会发出警告。脚本还会记录 Codex 执行过的每条命令和退出码。
- **安全边界**：
  - 只用 `workspace-write` 沙箱，不使用 `danger-full-access`；
  - 沙箱默认不联网；
  - 不自动 commit、push、merge 或部署；
  - 任务文件和日志都放在系统临时目录，不进你的仓库。

## 安装

前置条件：已安装 [Claude Code](https://claude.com/claude-code)，已安装并登录 [Codex CLI](https://developers.openai.com/codex)（`codex login status`），另外需要 `jq` 和 `git`。

```bash
git clone https://github.com/voyokee/codex-worker.git
cd codex-worker
./install.sh
```

可选：把 [`examples/CLAUDE.md`](examples/CLAUDE.md) 里的规则加到 `~/.claude/CLAUDE.md`，让「默认不用 Codex」成为全局规则。

装好后**新开一个 Claude Code 会话**才会加载。

## 使用

在一个 git 仓库里，明确要求使用 Codex：

```
/codex-worker 给用户列表加分页，每页 20 条，带测试
```

或者用自然语言：「这个功能让 codex 做」「用 codex 实现 X」「交给 codex」「use codex to …」。

每个任务都需要单独要求，上一个任务用了 Codex 不代表下一个也会用。

如果想彻底禁止 Claude 自行调用，只允许 `/codex-worker` 触发，可以在 `SKILL.md` 的 frontmatter 里加一行 `disable-model-invocation: true`。

### 可选环境变量

| 变量 | 作用 |
|---|---|
| `CODEX_WORKER_MODEL=<model>` | 指定 Codex 使用的模型（默认读取 `~/.codex/config.toml`） |
| `CODEX_WORKER_NETWORK=1` | 允许沙箱联网（Skill 规定开启前要先征得你同意） |

## 文件结构

```
skills/codex-worker/
├── SKILL.md                    # 完整流程与硬性规则
├── scripts/codex-run.sh        # 调用 codex exec / resume 并记录改动
└── references/task-template.md # 任务规格模板 + 修复反馈模板
examples/CLAUDE.md              # 可选的全局规则
install.sh
```

也可以单独使用辅助脚本：

```bash
skills/codex-worker/scripts/codex-run.sh start  <repo_dir> <task_file>
skills/codex-worker/scripts/codex-run.sh resume <repo_dir> <session_id> <feedback_file>
```

已在 Codex CLI 0.165 上测试。

## License

MIT
