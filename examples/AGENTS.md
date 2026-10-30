# Working style

## External workers are opt-in
- Do not use an external worker (the `agent-dispatch` skill, or the `codex`, `claude` or `cursor` CLI as a worker) unless I explicitly ask for it in the current request, e.g. `/agent-dispatch`, "用 codex", "让 claude 做", "交给 cursor".
- Otherwise do all work myself, however large the task. Do not suggest switching to a worker unprompted.
- When I do ask for a worker: I plan and set acceptance criteria, the worker implements, I verify the real diff myself and give the final verdict. The worker's own report is never proof.
- If this session is itself running as a worker (`AGENT_DISPATCH_WORKER=1` is set), never start another worker.
