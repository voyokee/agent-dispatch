# Task spec template for Codex

Copy this, fill every section, and save it outside the repo. Delete the hints in brackets.

```markdown
# Task: <short imperative title>

## Goal
<What the user wants and why, in one paragraph. Include the user-visible outcome.>

## Context
- Repository: <what it is, stack, how it is structured — only what matters for this task>
- Relevant files: <path — why it matters>
- Patterns to follow: <existing module/function to mimic, naming, error handling style>
- Decisions already made: <architecture choices Claude/the user settled; do not revisit>

## Scope
- In scope: <files/dirs Codex may change or create>
- Out of scope: <must not touch: public APIs, config, lockfiles, unrelated modules, ...>

## Acceptance criteria
1. <checkable behavior, e.g. "`foo --bar x` prints Y and exits 0">
2. <tests: "new tests in tests/test_foo.py cover A, B, edge case C">
3. <commands that must pass: `npm test -- foo`, `npm run lint`, `npm run typecheck`>

## Worker rules
- Work only inside this repository and only within the scope above.
- Some files may already have uncommitted changes from the user. Preserve them; do not revert, reformat, or overwrite unrelated hunks.
- Do not run git commit, push, merge, rebase, reset, checkout, stash, or clean. Leave all changes uncommitted.
- Do not delete or weaken existing tests, and do not special-case code to make tests pass.
- Do not add dependencies unless the task requires it; if you must, say so in the report.
- If something blocks you (missing dependency, no network, unclear requirement, a design conflict), stop and report it instead of guessing or working around it.
- If you disagree with the plan, implement the plan anyway unless it is clearly wrong, and explain your concern in the report.

## Report format (your final message)
### Summary
<2–4 sentences>
### Files changed
- <path>: <what and why>
### Verification run
- `<command>` → <result, with pass/fail counts>
### Acceptance criteria
1. <met / not met / not verified — evidence>
### Open issues and concerns
<anything unresolved, risky, or deviating from the spec; "none" if none>
```

# Repair feedback template

```markdown
# Repair round <n> for: <task title>

The reviewer checked your changes and found the problems below. Fix only these; keep everything else as it is.

## Findings
1. <file:line> — <what is wrong> — evidence: <failing command output / diff excerpt>
2. ...

## Must not change
- <parts that were accepted>

## Then
Re-run: <commands>. Reply using the same report format as before.
```
