# Review rules for the Master

These apply after every worker run (`start` and each `resume`), whichever agent is Master and whichever CLI was the worker.

## Verify independently

Do all of these yourself; do not skip any because the worker says it passed:

1. Read `summary.txt` (or `summary.json`).
   - `status: failed` or a `worker_error`: read `stderr.log` and the report before anything else.
   - `HEAD moved` / `head_moved: true`: the worker committed against the rules. The commits are listed; the changed-files list includes their files. Tell the user, and do not rewrite history yourself.
   - `user_files_touched` / the overlap warning: the worker edited files that already had the user's uncommitted changes. Check those hunks with extra care and mention it to the user.
2. Read the worker's report (`last-message.md`) to know what it *claims*, then check every claim.
3. Inspect the real diff: `git diff --stat`, `git diff`, `git diff --check`, and read new untracked files listed in changed-files. If HEAD moved, also `git diff <head_before> <head_after>`. Anything outside the agreed scope is a finding.
4. Run the project's own verification yourself: tests relevant to the change, plus lint/typecheck/build when the project has them. For behavior changes, exercise the behavior (run the CLI, hit the endpoint, run the app) when feasible. If you cannot run something, say so; do not substitute the worker's output.
5. Judge against each acceptance criterion and against design quality: matches existing patterns, no dead code, no weakened/deleted tests, no hard-coded test bypasses, no secrets, no unrelated reformatting.

Verdict: **PASS** only if every acceptance criterion is verified by your own evidence and no blocking design issue remains. Otherwise **FAIL** with a numbered findings list, or **ESCALATE** if blocked / repair limit reached / safety boundary crossed.

## Repair feedback

Use the repair template at the end of `task-template.md`. Each finding gives:
- where (`file:line`), what is wrong, and the evidence (failing output, diff excerpt);
- what must not change (parts already accepted);
- the commands to re-run and the same report format.

Then resume the same session so the worker keeps its context and `task_id`:

```bash
bash "<skill_dir>/scripts/worker-run.sh" resume "<repo_dir>" "<session_id>" "<feedback_file>"
```

Re-run the full verification after each round. Default limit: 2 repair rounds. After that, stop delegating and escalate (see SKILL.md). If the worker reports it is blocked (needs network, credentials, a design decision), resolve it with the user rather than retrying blindly.

## Keep the review record and commit the structured verdict

After each verdict, write your review next to the run's evidence and register the structured verdict in the persistent Task Ledger:

1. Write `<run_dir>/review.md`: the verdict (`PASS` / `FAIL` / `ESCALATE`), the commands you ran with results, and the numbered findings.
2. If you wrote a repair feedback file, copy it to `<run_dir>/feedback.md`.
3. Register the verdict with `dispatchctl.sh` (only after independent verification and writing `review.md`):
   ```bash
   bash "<skill_dir>/scripts/dispatchctl.sh" review \
     --run "<run_dir>" \
     --verdict <PASS|FAIL|ESCALATE> \
     --evidence "<run_dir>/review.md"
   ```
   - `status: completed` in `summary.json` only means the worker process exited cleanly; `dispatchctl.sh stats` only counts a task as accepted when a `PASS` review record is committed.
   - Re-submitting the identical verdict for a run is idempotent; changing an existing verdict requires `--force`.

These files and records never replace telling the user.
