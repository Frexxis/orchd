# orchd

[![CI](https://github.com/Frexxis/orchd/actions/workflows/ci.yml/badge.svg)](https://github.com/Frexxis/orchd/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**Autonomous AI agent orchestrator for software engineering.**

orchd takes a high-level project description, breaks it into a dependency graph of tasks, spawns AI coding agents in parallel, runs quality gates, and merges completed work back into your main branch — with or without human oversight.

Why orchd? Modern AI coding tools are powerful but single-session. orchd turns multiple agent sessions into a coordinated delivery pipeline: parallel worktrees, DAG-ordered merges, retries, and a shared project memory so agents learn from each other.

## How It Works

```
You: "Build a REST API with auth, tests, and CI"
                    │
                    ▼
        ┌───────────────────────┐
        │    orchd plan          │  → AI generates task DAG
        │    orchd autopilot     │  → fully autonomous loop
        └───────────────────────┘
                    │
                    ▼
            Done. Ship it.
```

Or step-by-step:

```
orchd plan → orchd spawn --all → orchd board --watch → orchd check --all → orchd merge --all
```

Or use the rich terminal UI:

```bash
orchd tui
```

## Quick Start

```bash
# Install
git clone https://github.com/Frexxis/orchd.git
cd orchd && chmod +x bin/orchd
mkdir -p ~/.local/bin && ln -sf "$PWD/bin/orchd" ~/.local/bin/orchd

# Initialize in your project
cd /path/to/your/project
orchd init .

# Plan → Autopilot (fully autonomous)
orchd plan "build a REST API with auth, tests, and CI"
orchd autopilot

# Or step-by-step:
orchd plan "build a REST API with auth, tests, and CI"
orchd spawn --all
orchd board --watch
orchd check --all
orchd merge --all
```

## Architecture

```
┌──────────────────────────────────────────────────────┐
│                  orchd orchestrator                   │
│                                                      │
│  plan ──► spawn ──► monitor ──► check ──► merge      │
│    │        │          │          │          │        │
│    ▼        ▼          ▼          ▼          ▼        │
│  ┌────┐ ┌──────────────────────────────┐ ┌────────┐  │
│  │ AI │ │     Agent Pool (tmux)        │ │ Git    │  │
│  │DAG │ │                              │ │ Merge  │  │
│  │    │ │ ┌────────┐ ┌────────┐        │ │ Queue  │  │
│  │ T1 │ │ │Agent 1 │ │Agent 2 │ ...    │ │        │  │
│  │ T2─┤ │ │backend │ │frontend│        │ │ T1→main│  │
│  │ T3 │ │ │worktree│ │worktree│        │ │ T2→main│  │
│  └────┘ │ └────────┘ └────────┘        │ │ T3→main│  │
│         └──────────────────────────────┘ └────────┘  │
│                                                      │
│  Runners: codex │ claude │ opencode │ aider │ custom │
└──────────────────────────────────────────────────────┘
```

## Commands

### Orchestration (main workflow)

| Command | Description |
|---------|-------------|
| `orchd init [dir] [description]` | Initialize orchd in a project (creates `.orchd.toml`) |
| `orchd plan [--runner <runner>] "<description>"` | Use AI to generate a task DAG from a description |
| `orchd plan --file <path>` | Load/parse an existing plan output file into `.orchd/tasks/` |
| `orchd plan --stdin` | Read plan output from stdin and parse into `.orchd/tasks/` |
| `orchd review [ref]` | Run review-only agent on changes or a ref |
| `orchd spawn <task\|--all> [-r\|--runner <runner>]` | Create git worktrees and launch AI agents |
| `orchd resume <task> [reason...]` | Resume/continue a task in its existing worktree |
| `orchd board [--watch]` | Live terminal dashboard showing all agent status |
| `orchd tui [--project <dir>]` | Rich interactive terminal UI (multi-panel + live logs) |
| `orchd state [--json]` | Print a snapshot of task state (machine-friendly) |
| `orchd await [--all\|<task>]` | Block until a task changes or an agent exits |
| `orchd check <task\|--all>` | Run quality gates (lint, test, build, task report) |
| `orchd merge <task\|--all>` | Merge completed tasks in dependency order |
| `orchd autopilot [poll_seconds]` | Fully autonomous: spawn/check/merge loop |
| `orchd autopilot --continuous [poll_seconds]` | Fully autonomous until the project is complete (ideate → plan → execute) |
| `orchd autopilot --daemon [poll_seconds]` | Run autopilot in background |
| `orchd autopilot --daemon --continuous` | Background + continuous ideation |
| `orchd autopilot --status\|--stop\|--logs` | Manage the autopilot daemon |

### Memory Bank

| Command | Description |
|---------|-------------|
| `orchd memory` | Show memory bank status |
| `orchd memory init` | Initialize memory bank scaffold (`docs/memory/`) |
| `orchd memory show` | Print all memory bank contents |
| `orchd memory update` | Update progress/context from current task state |
| `orchd memory reset --force` | Remove all memory bank files |

### Idea Queue

| Command | Description |
|---------|-------------|
| `orchd idea "<idea>"` | Queue an idea for continuous autopilot |
| `orchd idea list` | List all queued ideas with status |
| `orchd idea count` | Show number of pending ideas |
| `orchd idea clear --force` | Remove all pending ideas |

### Ideation

| Command | Description |
|---------|-------------|
| `orchd ideate` | Ask the AI for the next 1–5 ideas from `docs/memory/` + codebase context |
| `orchd ideate --dry-run` | Show suggested ideas without queueing |
| `orchd ideate --runner <runner>` | Override runner for ideation |

### Fleet Management

| Command | Description |
|---------|-------------|
| `orchd fleet list` | List configured fleet projects |
| `orchd fleet autopilot [poll_seconds]` | Start autopilot daemon for all fleet projects |
| `orchd fleet status` | Show autopilot status for all projects |
| `orchd fleet stop` | Stop all fleet autopilot daemons |
| `orchd fleet brief [hours]` | Summary of recent activity (default 24h) |

### Utilities

| Command | Description |
|---------|-------------|
| `orchd doctor [dir]` | Show effective config and auto-detected quality commands |
| `orchd refresh-docs [dir]` | Refresh AGENTS, WORKER, ORCHESTRATOR, CLAUDE, OPENCODE, orchestrator-runbook |

### Monitor (background repo watcher)

| Command | Description |
|---------|-------------|
| `orchd start [dir] [interval]` | Start background git monitor (tmux daemon) |
| `orchd list` | List active monitor sessions |
| `orchd status <session>` | Show latest snapshot |
| `orchd attach <session>` | Attach to monitor session |
| `orchd stop <session>` | Stop monitor |

## Supported AI Runners

orchd auto-detects your installed AI CLI tool, or you can set it in `.orchd.toml`:

| Runner | CLI | Status |
|--------|-----|--------|
| Codex CLI | `codex` | Supported |
| Claude Code | `claude` | Supported |
| OpenCode | `opencode` | Supported |
| Aider | `aider` | Supported |
| Custom | any | Supported (via template) |

## Terminal UI

`orchd tui` launches a full-screen TUI built with Bubbletea for interactive orchestration.

Features:

- Large ASCII `orchd` banner + tabbed layout (`Tasks`, `Logs`, `DAG`, `Memory`, `Queue`, `Stats`)
- Live task list with status and dependency-aware details
- Built-in actions: spawn, check, merge, resume
- Live log tail for selected task log + global `.orchd/orchd.log`
- Fast state refresh via filesystem watch + periodic polling fallback
- Mouse wheel/click support for navigation and selection
- Color-coded status chips and card-style panels for easier scanning
- Memory bank, idea queue, DAG, and project statistics views

Shortcuts:

- `1-6`: switch tabs
- `tab`: switch pane
- `j/k` or `up/down`: navigate
- `s/c/m/x`: spawn/check/merge/resume selected task
- `S/C/M`: run `--all` variants
- `a`: attach to selected task's tmux session
- `/`: set/clear log filter (Logs tab)
- `f`: toggle live log follow mode
- `g` / `G`: jump to top / bottom in active pane
- `n`: add a new queued idea (Queue tab)
- `d`: cancel selected queued idea (Queue tab)
- `e`: open selected memory file in `$VISUAL`/`$EDITOR` (Memory tab)
- `r`: refresh now
- `?`: help
- `q`: quit

Install/build (from this repo):

```bash
make build-tui
./bin/orchd-tui
```

When you run `./bin/orchd tui` from a source checkout, orchd now auto-rebuilds the local `bin/orchd-tui` if Go sources are newer than the binary.

## Configuration

After `orchd init`, edit `.orchd.toml`:

```toml
[project]
name = "my-project"
description = "A REST API with authentication"
base_branch = "main"

[orchestrator]
max_parallel = 3           # max concurrent agents
worktree_dir = ".worktrees"
monitor_interval = 30      # monitor daemon tick (legacy)
board_refresh = 5          # orchd board --watch refresh seconds

[worker]
runner = "claude"          # or: codex, opencode, aider, custom

[quality]
lint_cmd = "npm run lint"  # run during orchd check
test_cmd = "npm test"      # run during orchd check
build_cmd = "npm run build"

[ideate]
max_ideas = 5                    # max ideas per ideate call
cooldown_seconds = 30             # cooldown between ideate cycles in --continuous
max_cycles = 20                   # max ideate cycles before stopping
max_consecutive_failures = 3       # stop if ideate fails this many times in a row

# [runners.codex]
# codex_bin = "codex"
# codex_flags = "--dangerously-bypass-approvals-and-sandbox"

# [runners.claude]
# claude_bin = "claude"

# [runners.custom]
# custom_runner_cmd = "my-agent --prompt {prompt} --dir {worktree}"
```

**Optional overrides** (with defaults):

| Key | Default | Description |
|-----|---------|-------------|
| `memory_max_chars` | 12000 | Max characters for memory bank context in prompts |
| `autopilot_poll` | 30 | Poll interval (seconds) in autopilot loop |
| `autopilot_max_iterations` | 0 | Max autopilot iterations (0 = unlimited) |
| `autopilot_retry_limit` | 2 | Max retries per failed task |
| `autopilot_retry_backoff` | 60 | Base backoff (seconds) between retries |
| `await_poll` | 5 | Poll interval for `orchd await` |
| `await_timeout` | 0 | Timeout for `orchd await` (0 = no limit) |

If `lint_cmd`, `test_cmd`, or `build_cmd` are left empty, `orchd check` auto-detects commands for Node, Python, Go, Rust, and Java projects.

## Project Structure

```
orchd/
├── bin/orchd                      # Main entry point / dispatcher
├── lib/
│   ├── core.sh                    # Config, state, worktree, logging, memory, queue, fleet
│   ├── runner.sh                  # Multi-runner adapter system
│   └── cmd/
│       ├── init.sh                # orchd init
│       ├── plan.sh                # orchd plan (AI task DAG generation)
│       ├── review.sh              # orchd review (review-only)
│       ├── spawn.sh               # orchd spawn (worktree + agent launch)
│       ├── board.sh               # orchd board (live TUI dashboard)
│       ├── check.sh               # orchd check (quality gates)
│       ├── merge.sh               # orchd merge (DAG-ordered integration)
│       ├── autopilot.sh           # orchd autopilot (autonomous loop + queue drain)
│       ├── resume.sh              # orchd resume (continuation)
│       ├── state.sh               # orchd state (task state snapshot)
│       ├── await.sh               # orchd await (block until task/agent change)
│       ├── memory.sh              # orchd memory (memory bank management)
│       ├── idea.sh                # orchd idea (idea queue)
│       ├── ideate.sh              # orchd ideate (AI-driven idea generation)
│       ├── fleet.sh               # orchd fleet (multi-project management)
│       ├── doctor.sh              # orchd doctor (effective config)
│       └── refresh_docs.sh         # orchd refresh-docs (policy docs)
├── templates/
│   ├── plan.prompt                # Prompt template for task planning
│   ├── kickoff.prompt             # Prompt template for agent kickoff
│   ├── continue.prompt            # Prompt template for task continuation
│   ├── review.prompt              # Prompt template for review-only tasks
│   └── ideate.prompt              # Prompt template for ideation
├── AGENTS.md                      # Shared agent rules + role routing
├── ORCHESTRATOR.md                # Orchestrator-specific rules
├── WORKER.md                      # Task agent rules
├── CLAUDE.md                      # Claude Code entry pointer
├── OPENCODE.md                    # OpenCode entry pointer
├── orchestrator-runbook.md        # Comprehensive orchestration runbook
├── tests/config_get.sh            # Config parser regression tests
├── tests/smoke.sh                 # End-to-end smoke tests
├── .github/workflows/ci.yml       # CI: ShellCheck + config/smoke tests (Ubuntu/macOS)
├── LICENSE
└── README.md
```

## The Runbook

`orchestrator-runbook.md` is a 17-section decision-support document covering:

Core principles, roles, agent CLI standards, prompt contracts, launch sequences, parallelization decisions, checkpoint design, merge queue rules, quality gate minimums, conflict recovery, evidence standards, secret hygiene, handoff protocols, anti-patterns, command reference, success criteria, and further reading.

> The runbook is tool-agnostic. Examples use Codex CLI, but the principles apply to any agent runner.

## How orchd Works Internally

1. **`orchd plan`** sends your project description to an AI runner with a structured prompt template. The AI returns a task DAG (dependency graph). orchd parses this into individual task state files under `.orchd/tasks/`.

2. **`orchd spawn`** reads the DAG, finds tasks whose dependencies are satisfied, creates a git worktree + branch (`agent-<task-id>`) for each, builds a kickoff prompt from the template, and launches the AI agent in a tmux session.

3. **`orchd board`** reads task state files and checks tmux sessions to show a live dashboard with status, progress bar, and agent health.

4. **`orchd check`** verifies each task: agent exited, commits exist on branch, TASK_REPORT.md present with evidence and rollback note, lint/test/build pass. Tasks that pass are marked `done`. Tasks that fail are marked `failed`. If the agent writes `.orchd_needs_input.md` (or legacy `BLOCKER.md`), the task is marked `needs_input`.

5. **`orchd merge`** performs topological sort on the DAG and merges `done` tasks into the base branch in dependency order. Post-merge regression tests run before marking a task as `merged`. If a merge conflicts, the task is marked `conflict` until you resolve and retry.

6. **`orchd resume`** re-launches an agent for an existing task/worktree with a continuation prompt (useful after a failed check).

7. **`orchd autopilot`** combines all of the above: spawn ready tasks, poll until agents finish, check quality gates, retry failed tasks (bounded + backoff), merge in DAG order, spawn newly unblocked tasks. When all tasks reach a terminal state (`merged`/`failed`/`needs_input`/`conflict`) or deadlock, it drains the idea queue. With `--continuous`, it then runs `orchd ideate` to generate new work until the AI outputs `PROJECT_COMPLETE`.

## Memory Bank

orchd maintains a structured project memory under `docs/memory/` (git-tracked) inspired by [Cline Memory Bank](https://docs.cline.bot/improving-your-experience/memory-bank). The memory bank gives every AI agent persistent context about the project — goals, architecture decisions, current progress, and lessons learned from previous tasks.

**Files:**

| File | Purpose |
|------|---------|
| `projectbrief.md` | Project goals, scope, and product context |
| `techContext.md` | Tech stack, tooling, and development setup |
| `systemPatterns.md` | Architecture patterns and design decisions |
| `activeContext.md` | Current orchestration state (auto-updated) |
| `progress.md` | Task progress snapshot (auto-updated) |
| `lessons/` | Per-task lesson files (worker-authored, with orchestrator fallback) |

**How it works:**

1. `orchd memory init` creates the scaffold. You fill in `projectbrief.md` and `techContext.md`.
2. When agents are spawned or resumed, `memory_read_context()` concatenates all memory files (respecting `memory_max_chars` budget, default 12000) and injects them into the prompt via the `{memory_context}` token.
3. After a successful merge, orchd preserves worker-authored `docs/memory/lessons/{task_id}.md` files; if one is missing, it writes a fallback lesson from task report evidence. It then updates `progress.md` mechanically (no AI call).
4. Use `orchd memory update` to refresh `activeContext.md` and `progress.md` mechanically from task state.
5. `orchd plan` and `orchd ideate` also read the memory bank, so planning and ideation benefit from accumulated project knowledge.

Workers can write lesson files keyed by task ID for conflict-free history across parallel tasks.

## Idea Queue

The idea queue lets you feed orchd a backlog of ideas that get executed one-by-one in autopilot.

```bash
# Queue some ideas
orchd idea "add rate limiting to the API"
orchd idea "write integration tests for auth flow"
orchd idea "add OpenAPI spec generation"

# Start autopilot — it will plan and execute tasks,
# then pop the next idea, run orchd plan, and continue
orchd autopilot

# Fully autonomous mode (no human idea entry):
# when the queue is empty, orchd will ideate new work from docs/memory
orchd autopilot --continuous
```

**How it works:**

1. `orchd idea "..."` appends a line to `.orchd/queue.md` with `- [ ]` (pending) status.
2. When `orchd autopilot` reaches a terminal state (all tasks merged/failed/needs_input/conflict), it calls the queue drain.
3. The drain pops the next pending idea (marks it `[>]` in-progress), runs `orchd plan "$idea"` to generate a fresh task DAG, and restarts the autopilot loop.
4. When that idea's tasks complete, the idea is marked `[x]` (done) and the next one is popped.
5. This continues until the queue is empty. With `orchd autopilot --continuous`, orchd runs `orchd ideate` to generate the next backlog. When the AI outputs `PROJECT_COMPLETE`, autopilot stops.

Ideas keep a full audit trail in `queue.md` — you can see which ideas were completed, which are in-progress, and which are still pending. If no AI runner is available, queue drain is skipped and ideas are preserved.

## Fleet Mode

Fleet mode manages multiple orchd projects from a single command. Define your projects in `~/.orchd/fleet.toml`:

```toml
[projects.api]
path = "/home/user/projects/my-api"

[projects.frontend]
path = "/home/user/projects/frontend"

[projects.docs]
path = "/home/user/projects/documentation"
```

**Commands:**

- `orchd fleet autopilot [poll_seconds]` — starts a background autopilot daemon for each valid orchd project. Each project runs independently with its own log file (`.orchd/autopilot.log`) and PID file (`.orchd/autopilot.pid`).
- `orchd fleet status` — shows a table with autopilot state, task progress (merged/total), and running/failed counts per project.
- `orchd fleet stop` — sends SIGTERM to all running fleet daemons.
- `orchd fleet brief [hours]` — summarizes recent activity across all projects by parsing `orchd.log` and reading task state. Defaults to last 24 hours. Shows merged/failed/needs_input counts, autopilot status, and pending queue depth per project.

Fleet mode combined with the idea queue enables fully autonomous multi-project operation: queue ideas for each project, run `orchd fleet autopilot`, and let orchd work through everything.

## Requirements

- `git`, `tmux`
- Standard Unix utilities (`awk`, `diff`, `cmp`, `sort`, `sed`)
- At least one AI runner: `codex`, `claude`, `opencode`, or `aider`

## Testing

```bash
./tests/smoke.sh              # Run smoke test suite
shellcheck bin/orchd lib/*.sh lib/cmd/*.sh tests/smoke.sh
```

## Design Principles

- **Fully autonomous** — from planning to merge with minimal human intervention
- **Runner-agnostic** — plug in any AI CLI tool
- **Zero framework dependencies** — pure Bash, git, tmux
- **DAG-first** — dependency graph drives parallelism and merge order
- **Evidence-based** — no task is merged without quality gate proof
- **Safe by default** — worktree isolation, no-force merges, post-merge regression

## Contributing

Contributions welcome:

- New runner adapters
- TUI improvements for `orchd board`
- More quality gate checks
- Packaging (Homebrew, AUR, etc.)
- Real-world usage reports

## License

MIT (see [LICENSE](LICENSE)).
