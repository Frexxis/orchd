# orchd

Autonomous AI agent orchestrator for software engineering.

Tell orchd what to build. It breaks the project into tasks, spawns AI agents in parallel, monitors their progress, runs quality gates, and merges everything — fully autonomous.

## How It Works

```
You: "Build a REST API with auth, tests, and CI"
                    │
                    ▼
        ┌───────────────────────┐
        │    orchd plan          │  → AI generates task DAG
        │    orchd spawn --all   │  → agents start in parallel
        │    orchd board --watch │  → live dashboard
        │    orchd check --all   │  → quality gates
        │    orchd merge --all   │  → DAG-ordered merge
        └───────────────────────┘
                    │
                    ▼
            Done. Ship it.
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

# Plan → Spawn → Monitor → Check → Merge
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

### Orchestration (the main workflow)

| Command | Description |
|---|---|
| `orchd init [dir]` | Initialize orchd in a project (creates `.orchd.toml`) |
| `orchd plan "<description>"` | Use AI to generate a task DAG from a description |
| `orchd spawn <task\|--all>` | Create git worktrees and launch AI agents |
| `orchd board [--watch]` | Live terminal dashboard showing all agent status |
| `orchd check <task\|--all>` | Run quality gates (lint, test, build, task report) |
| `orchd merge <task\|--all>` | Merge completed tasks in dependency order |

### Monitor (background repo watcher)

| Command | Description |
|---|---|
| `orchd start [dir] [interval]` | Start background git monitor (tmux daemon) |
| `orchd list` | List active monitor sessions |
| `orchd status <session>` | Show latest snapshot |
| `orchd attach <session>` | Attach to monitor session |
| `orchd stop <session>` | Stop monitor |

## Supported AI Runners

orchd auto-detects your installed AI CLI tool, or you can set it in `.orchd.toml`:

| Runner | CLI | Status |
|---|---|---|
| Codex CLI | `codex` | Supported |
| Claude Code | `claude` | Supported |
| OpenCode | `opencode` | Supported |
| Aider | `aider` | Supported |
| Custom | any | Supported (via template) |

## Configuration

After `orchd init`, edit `.orchd.toml`:

```toml
[project]
name = "my-project"
description = "A REST API with authentication"
base_branch = "main"

[orchestrator]
runner = "claude"          # or: codex, opencode, aider, custom
max_parallel = 3           # max concurrent agents
worktree_dir = ".worktrees"
monitor_interval = 30

[quality]
lint_cmd = "npm run lint"  # run during orchd check
test_cmd = "npm test"      # run during orchd check
build_cmd = "npm run build"

# [runners.custom]
# custom_runner_cmd = "my-agent --prompt {prompt} --dir {worktree}"
```

## Project Structure

```
orchd/
├── bin/orchd                    # Main entry point / dispatcher
├── lib/
│   ├── core.sh                  # Config, state, worktree, logging
│   ├── runner.sh                # Multi-runner adapter system
│   └── cmd/
│       ├── init.sh              # orchd init
│       ├── plan.sh              # orchd plan (AI task DAG generation)
│       ├── spawn.sh             # orchd spawn (worktree + agent launch)
│       ├── board.sh             # orchd board (live TUI dashboard)
│       ├── check.sh             # orchd check (quality gates)
│       └── merge.sh             # orchd merge (DAG-ordered integration)
├── templates/
│   ├── plan.prompt              # Prompt template for task planning
│   └── kickoff.prompt           # Prompt template for agent kickoff
├── orchestrator-runbook.md      # Comprehensive orchestration runbook
├── tests/smoke.sh               # Smoke tests (34 tests)
├── .github/workflows/ci.yml    # CI: ShellCheck + smoke tests
├── LICENSE
└── README.md
```

## The Runbook

`orchestrator-runbook.md` is a 17-section decision-support document covering:

Core principles, roles, agent CLI standards, prompt contracts, launch sequences, parallelization decisions, checkpoint design, merge queue rules, quality gate minimums, conflict recovery, evidence standards, secret hygiene, handoff protocols, anti-patterns, command reference, success criteria, and further reading.

> The runbook is tool-agnostic. Examples use Codex CLI, but the principles apply to any agent runner.

## How orchd Works Internally

1. **`orchd plan`** sends your project description to an AI runner with a structured prompt template. The AI returns a task DAG (dependency graph). orchd parses this into individual task state files under `.orchd/tasks/`.

2. **`orchd spawn`** reads the DAG, finds tasks whose dependencies are satisfied, creates a git worktree + branch for each, builds a kickoff prompt from the template, and launches the AI agent in a tmux session.

3. **`orchd board`** reads task state files and checks tmux sessions to show a live dashboard with status, progress bar, and agent health.

4. **`orchd check`** verifies each task: agent exited, commits exist on branch, TASK_REPORT.md present, lint/test/build pass. Tasks that pass all gates are marked `done`.

5. **`orchd merge`** performs topological sort on the DAG and merges `done` tasks into the base branch in dependency order, with post-merge regression tests.

## Requirements

- `git`, `tmux`
- Standard Unix utilities (`awk`, `diff`, `cmp`, `sort`, `sed`)
- At least one AI runner: `codex`, `claude`, `opencode`, or `aider`

## Testing

```bash
./tests/smoke.sh              # 34 smoke tests
shellcheck bin/orchd lib/*.sh lib/cmd/*.sh tests/smoke.sh
```

## Design Principles

- **Fully autonomous** — from planning to merge, no human intervention required
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
