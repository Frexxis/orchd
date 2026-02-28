# Orchestrator Runbook

This document defines how a multi-agent delivery model is managed by a single responsible orchestrator with minimal friction.
Goal: fast but safe progress, low conflict rate, high quality evidence.

Note: This runbook is tool-agnostic. Examples use Codex CLI; if you use a different agent runner, substitute the commands with their equivalents.

## 1) Core Principles

1. **Bridge-free orchestration:** Prompt distribution, tracking, collection, merge, and closeout are all owned by a single orchestrator.
2. **Dependency-first planning:** Parallelization is used only for independent tasks.
3. **Evidence before merge:** No task is marked `done` without test/lint/report evidence.
4. **Single source of truth:** Backlog + live board + memory bank stay in sync after every merge.
5. **Reversible integration:** Every step is taken with rollback in mind.

## 2) Roles and Responsibility Boundaries

- **Orchestrator:** Scope breakdown, DAG (dependency graph), merge queue, quality gate, closeout decision.
- **Domain Agent(s):** Feature implementation (application, API, data, AI/memory, etc.).
- **Quality Agent(s):** Regression, contract, consistency, CI quality gates.
- **Ops Agent(s):** Live board, queue, blocker, conflict watchlist tracking.

Note: Release notes/changelog and final memory/plan consolidation are the orchestrator's responsibility.

## 3) Codex CLI Operational Standard

In this runbook, agent sessions are executed non-interactively via Codex CLI.
Environment-specific settings (PATH, shell init, proxy, token) belong in local setup notes, not in this document.

### 3.1 CLI Invocation (General Rule)

The default invocation uses the `codex` command.

- Recommendation: Detect the active binary once with `CODEX_BIN="$(command -v codex)"` and use this variable in automation.
- Rule: Do not hard-code absolute paths in documentation; paths are environment-specific.
- Fallback: If the shell alias/function is ambiguous, invoke via `CODEX_BIN`.

Practical note:

- If `codex` is a shell function/alias, invoking the binary directly in orchestrator automation is more deterministic.

### 3.2 Session Lifecycle

A separate session is opened for each ticket and the same session is resumed for follow-ups.

- **Start:** `codex exec "<kickoff prompt>" -C <worktree> --json`
- **Resume:** `codex exec resume <thread_id> "<follow-up prompt>" --json`
- **Rule:** No new session is opened until the current ticket is closed (exception: session corruption).

### 3.3 JSON Event Logging

Recommended practice:

- All `codex exec` outputs are written to `.worktrees/<branch>/.logs/*.jsonl`.
- The `thread_id` from the `thread.started` event is noted on the live board.

### 3.4 Optional Smoke Test (exec + resume)

Purpose: Quickly verify that Codex CLI can (1) start a new session and (2) resume the same session.

```bash
set -euo pipefail

CODEX_BIN="${CODEX_BIN:-$(command -v codex)}"
OUT_DIR="${OUT_DIR:-/tmp/codex-orch-smoke}"
mkdir -p "$OUT_DIR"

# 1) Start a new session (capture thread_id)
"$CODEX_BIN" exec "Remember this exact token: SMOKE42. Reply only READY." \
  --json > "$OUT_DIR/ev1.jsonl"

THREAD_ID=$(jq -r 'select(.type=="thread.started")|.thread_id' "$OUT_DIR/ev1.jsonl" | head -n 1)

# 2) Resume the same session
"$CODEX_BIN" exec resume "$THREAD_ID" "What is the token? Reply only it." \
  --json > "$OUT_DIR/ev2.jsonl"

TOKEN=$(jq -r 'select(.type=="item.completed" and .item.type=="agent_message")|.item.text' "$OUT_DIR/ev2.jsonl" | tail -n 1)
test "$TOKEN" = "SMOKE42"

echo "OK: exec+resume works (thread_id=$THREAD_ID)"
```

### 3.5 Optional "Always-On" Watch Loop (tmux)

If the orchestrator needs to monitor the repo in the background after responding, the most practical method is a tmux loop.

- Monitor-only (safe): only reports `fetch/status` and branch SHA changes.
- Example: `orchd start <repo_dir> 30` (see `~/.local/bin/orchd --help`)

Most minimal alternative (no script, just tmux + `sleep`):

```bash
tmux new -d -s orch-monitor '
while true; do
  echo "== $(date -Is) =="
  git -C "<repo_dir>" fetch --all --prune >/dev/null 2>&1 || true
  git -C "<repo_dir>" status -sb || true
  sleep 60
done'
```

Note:

- The idea here is a "wait" with `sleep`, then "check again" loop.
- For a more active orchestrator, each loop iteration can send follow-ups to relevant agent sessions via `codex exec resume <thread_id> ...`, then return to `sleep`.

## 4) Prompt Contract (Recommended Minimum)

Every kickoff prompt includes the following header:

```text
AGENT: <agent-id-or-role>
TASK: <TASK-ID>
BRANCH: <branch>
WORKTREE: <path>
STATUS: <GO|PREP_ONLY|REVIEW|...>
```

In practice, the following 4 blocks are recommended:

1. **Goal** (what will be completed?)
2. **Scope** (in/out)
3. **Acceptance** (command + expected result)
4. **Deliverables** (file paths + task report)

## 5) Launch Sequence (Reference Flow)

1. **Preflight:** scope + dependency + risk check
2. **Worktree/branch creation:** according to policy
3. **Kickoff distribution:** independent tasks in parallel, dependent ones gated
4. **Checkpoint review:** collect interim evidence
5. **Final review:** verify lint/test/contract/build
6. **Merge queue:** integrate in dependency order
7. **Post-merge regression:** run full tests on main
8. **Sync:** update backlog + board + memory + changelog

## 5.1 Ops Artifacts (Name-Independent)

When this runbook refers to "backlog/board/memory/changelog", it means the following 4 artifacts (names may vary by project):

- **Backlog/plan:** ticket list, priority, dependencies
- **Live board:** current status, evidence, blockers, next action
- **Memory/decisions:** decisions, patterns, active risks (brief and verifiable)
- **Release notes:** changelog / closeout note

## 6) Parallelization Decision Matrix

### Start in parallel (generally yes)

- File ownership is disjoint
- Contract/interface is stable
- One task's output does not affect the other

### Start gated (generally safer)

- Migration IDs/revisions touch the same area
- Consumer layer is tightly coupled to provider output
- Policy/contract is not yet finalized

## 7) Checkpoint Design (Long-Running Tasks)

For long-running tasks, a two-checkpoint model is useful:

- **CP1 (structural):** core architecture + initial tests
- **CP2 (final):** full integration + documentation + evidence

Default gate rules:

- If CP1 is rejected, no transition to CP2
- If CP2 is missing quality gate evidence, no merge

## 8) Merge Queue Rules

1. Perform topological sort based on the DAG.
2. Merge branches that touch the same file group in sequence.
3. After each merge, run at minimum a targeted smoke test.
4. After the entire queue is drained, run a full regression suite.

## 9) Quality Gate Minimums

For each ticket, the following minimum evidence set is recommended (adapted to context):

- Lint or equivalent static analysis PASS
- Ticket-specific test/smoke PASS
- Task report complete
- Risk/rollback note present

For wave closeout, complete as much of the following as possible:

- System-wide full suite PASS (stack-dependent)
- Contract suite PASS (if applicable)
- UI/app analysis + test PASS (if applicable)
- Live board shows `done` + blocker `none`

## 10) Conflict and Recovery Playbook

### 10.1 Conflict Types

- **Schema/migration conflict** (most critical)
- **Contract drift** (endpoint/event/payload)
- **UI state / API payload drift**
- **Shared doc churn** (release notes/live board)

### 10.2 Resolution Strategy

1. Separate the conflict into technical and process dimensions.
2. Reference current main before modifying the source branch.
3. Maintain single-head constraint for migrations.
4. Immediately run the relevant test subset after resolution.

## 11) Evidence Standard

Agent reports should include command + result lines:

```text
EVIDENCE:
- CMD: <command>
  RESULT: PASS|FAIL
  OUTPUT: <brief summary>
```

Ops board rows should contain at minimum:

- Latest commit SHA
- Lint evidence
- Test evidence
- Blocker
- Next action

## 11.1 Secret and Credential Hygiene

- Do not include API keys, tokens, cookies, or refresh tokens in prompts.
- Provide required credentials/secrets via environment variables or a secret manager.
- Perform a quick scan of agent-generated logs/reports for secret leakage.

## 12) Handoff Protocol (For the Next Orchestrator)

At the end of each wave, the orchestrator leaves behind:

1. Closeout report (`<WAVE>-closeout-orchestrator.md` or equivalent)
2. Current queue state (done/in_progress/todo)
3. Active risks and open technical debt
4. Next 3 tickets ready to launch

Handoff output must be readable "at a glance".

## 13) Anti-Pattern List

Strongly avoid the following:

- Marking tasks `done` without evidence
- Full-executing dependent tickets simultaneously
- Forcing a merge before the agent report arrives
- Closing a wave on main without regression testing
- Patching conflicts with temporary hacks

## 14) Practical Command Reference

```bash
# Start a ticket
"${CODEX_BIN:-codex}" exec "<kickoff prompt>" -C .worktrees/<branch> --json

# Resume the same ticket
"${CODEX_BIN:-codex}" exec resume <thread_id> "<follow-up>" --json

# General quality gate (adapt to your project stack)
<lint-command>
<test-command>
<contract-command-optional>
<ui-analyze-and-test-optional>
```

## 15) Success Criteria

The orchestrator is considered successful when:

- Lead time decreases
- Rework rate decreases
- Merge conflict count decreases
- Regression-free delivery rate increases across wave closeouts

## 16) Judgment Margin

This runbook is a decision-support document, not a checklist.

- The orchestrator may adjust the weight of individual steps based on project reality.
- In critical situations, decisions favor risk reduction over speed.
- Any deviation from the standard is recorded with a brief justification note.

## 17) Web Resources (Reading List)

- Codex CLI repository/documentation: good reference for setup + CLI-based local agent workflows. (https://github.com/openai/codex)
- LangGraph: reference for thinking about orchestration as graphs/DAGs, durable execution, and human-in-the-loop concepts. (https://github.com/langchain-ai/langgraph)
- AutoGen: reference for event-driven multi-agent system approaches, multi-agent application and runtime concepts. (https://microsoft.github.io/autogen/stable/)
- CrewAI: reference for crew/flow/process concepts and guardrails/observability-focused multi-agent practices. (https://docs.crewai.com/)
