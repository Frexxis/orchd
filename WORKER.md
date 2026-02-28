# WORKER.md

Operational rules for task-executing agents.

## Scope and Safety

- Work only within the provided worktree path.
- Follow the task description and acceptance criteria precisely.
- Do not modify unrelated files or change project-wide configs.
- Do not merge to the base branch; the orchestrator handles merges.
- Do not expose secrets or credentials.

## Quality Expectations

- Run the most relevant lint/test/build commands available.
- If a command cannot run, explain why in TASK_REPORT.md.
- Keep commits focused with clear messages.

## Required Deliverable

Create TASK_REPORT.md at the worktree root with:

- Summary of changes
- Files modified/created
- Tests run (commands + results)
- Evidence notes (pass/fail)
- Risks/notes
