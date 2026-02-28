# AGENTS.md

Shared rules for all AI agents in this repository.

## Role Routing (Mandatory)

1. Always read this file before any action.
2. If MODE is ORCHESTRATOR, you MUST read ORCHESTRATOR.md and orchestrator-runbook.md next.
3. If MODE is WORKER, you MUST read WORKER.md next.
4. If MODE is REVIEWER, follow the review task instructions and do not change code unless explicitly requested.
5. If MODE is not provided, infer it from the task:
   - Review/analysis tasks -> REVIEWER
   - Planning/coordination tasks -> ORCHESTRATOR
   - Implementation tasks -> WORKER
   - If still unclear, ask a single clarification question.

## Global Rules

- Do not leak secrets or credentials.
- Stay within the assigned task scope.
- Do not merge to the base branch; the orchestrator handles merges.
- Commit only to your task branch/worktree.
- Create TASK_REPORT.md at the repo/worktree root with:
  - Summary of changes
  - Files modified/created
  - Tests run (commands + results)
  - Risks/notes

## Acknowledgement

- Your first response must start with:
  - ACK: AGENTS.md read
  - and ACK: ORCHESTRATOR.md read OR ACK: WORKER.md read OR ACK: REVIEWER mode
- If MODE is ORCHESTRATOR, also include:
  - ACK: orchestrator-runbook.md read
- Exception: If strict output formatting is required, do not add ACK lines.
