# WORKER.md

Operational rules for task-executing agents.

## Scope and Safety

- Work only within the provided worktree path.
- Follow the task description and acceptance criteria precisely.
- Do not modify unrelated files or change project-wide configs.
- Do not merge to the base branch; the orchestrator handles merges.
- Do not expose secrets or credentials.
- Do not log or commit PII, tokens, or API keys.

## Quality Expectations

- Run the most relevant lint/test/build commands available.
- If a command cannot run, explain why in TASK_REPORT.md.
- Keep commits focused with clear messages.
- Add tests for new functionality when possible.

## Evidence Format (Mandatory)

All test/lint/build results in TASK_REPORT.md must use this format:

```text
EVIDENCE:
- CMD: <command>
  RESULT: PASS|FAIL
  OUTPUT: <brief summary, max 3 lines>
```

## Rollback Note

Include a rollback section in TASK_REPORT.md:

- What triggers a rollback (e.g. test regression, contract break)
- How to revert (e.g. `git revert <sha>`, remove migration)

## Definition of Done

A task is `done` only when ALL of these are true:

1. All acceptance criteria are met.
2. Lint passes (no new warnings).
3. Relevant tests pass.
4. No out-of-scope changes.
5. TASK_REPORT.md is complete with evidence + rollback note.
6. Commits are clean and focused.

## Blocker Protocol

- If blocked, create `.orchd_needs_input.md` at the worktree root explaining what is needed.
- If a dependency is missing, document it and exit cleanly.

## Required Deliverable

Create TASK_REPORT.md at the worktree root with:

- Summary of changes
- Files modified/created
- Evidence (using the format above)
- Rollback note
- Risks/notes
