# orchd

Minimal toolkit + runbook for **multi-agent engineering orchestration**.

Coordinate multiple AI coding agents working in parallel on a single codebase — with clear dependency ordering, evidence-based quality gates, and conflict-free merges.

## Why orchd?

When you run multiple AI agents (Codex CLI, Copilot, Cursor, etc.) on the same repo, things break fast: merge conflicts, untested code sneaking in, no visibility into what each agent is doing. **orchd** solves this with:

- **A runbook** — battle-tested decision framework for orchestrating parallel agent work (dependency DAG, checkpoint design, merge queue rules, quality gates)
- **A monitor** — lightweight tmux daemon that watches your repo for branch/ref changes in real time, without touching your code

No frameworks, no dependencies beyond `git` and `tmux`. Just a single shell script and a runbook.

## Architecture

```
┌──────────────────────────────────────────────┐
│            Human / AI Orchestrator           │
│         (follows orchestrator-runbook)       │
├──────────────────────────────────────────────┤
│                                              │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐     │
│  │ Domain   │ │ Quality  │ │   Ops    │     │
│  │ Agents   │ │ Agents   │ │  Agents  │     │
│  └────┬─────┘ └────┬─────┘ └────┬─────┘     │
│       └─────────────┼────────────┘           │
│                     │                        │
│          ┌──────────▼──────────┐             │
│          │   Git Repository    │             │
│          │  (branch-per-task)  │             │
│          └──────────┬──────────┘             │
│                     │                        │
│          ┌──────────▼──────────┐             │
│          │   orchd monitor     │  ← bin/orchd│
│          │  (tmux daemon)      │             │
│          │  - git fetch + diff │             │
│          │  - ref tracking     │             │
│          │  - change logging   │             │
│          └─────────────────────┘             │
│                                              │
│  State: ~/.orchd/<session>/                  │
│    ├── snapshot.txt   (latest git status)    │
│    ├── refs.last      (previous ref state)   │
│    └── changes.log    (append-only diff log) │
└──────────────────────────────────────────────┘
```

## What's Included

| File | Description |
|---|---|
| `bin/orchd` | Tiny tmux-based git monitor daemon (~170 lines of Bash) |
| `orchestrator-runbook.md` | Comprehensive orchestration runbook (tool-agnostic; Codex CLI examples) |

## Requirements

- `git`
- `tmux`
- Standard Unix utilities (`awk`, `diff`, `cmp`, `sort`, `sed`)

## Install

```bash
git clone https://github.com/Frexxis/orchd.git
cd orchd
chmod +x bin/orchd
mkdir -p ~/.local/bin
ln -sf "$PWD/bin/orchd" ~/.local/bin/orchd
```

Make sure `~/.local/bin` is in your `PATH`.

## Usage

### Start monitoring a repo

```bash
orchd start /path/to/repo 30    # fetch every 30 seconds
```

### Check active monitors

```bash
orchd list
```

### View status and latest snapshot

```bash
orchd status orchd-<repo>
```

### Attach to the monitor session (live view)

```bash
orchd attach orchd-<repo>
```

### Stop monitoring

```bash
orchd stop orchd-<repo>
```

### Full help

```bash
orchd --help
```

## Configuration

orchd is configured via environment variables:

| Variable | Default | Description |
|---|---|---|
| `ORCHD_BRANCH_REGEX` | `^origin/(main\|agent-\|orchestrator/)` | Regex filter for which remote refs to track |
| `ORCHD_STATE_DIR` | `~/.orchd` | Directory for state files |
| `ORCHD_SESSION` | `orchd-<repo_basename>` | Override auto-generated session name |

## The Runbook

The `orchestrator-runbook.md` covers 17 sections of practical orchestration guidance:

1. **Core Principles** — bridge-free orchestration, dependency-first planning, evidence before merge
2. **Roles** — orchestrator, domain agents, quality agents, ops agents
3. **Agent CLI Standard** — session lifecycle, JSON event logging, smoke tests
4. **Prompt Contract** — minimum fields for kickoff prompts (agent, task, branch, status)
5. **Launch Sequence** — preflight, worktree setup, kickoff, checkpoint, review, merge, regression, sync
6. **Parallelization Matrix** — when to run agents in parallel vs. gated
7. **Checkpoint Design** — structural (CP1) and final (CP2) checkpoints
8. **Merge Queue Rules** — topological sort by dependency DAG
9. **Quality Gate Minimums** — lint, test, task report, risk/rollback notes
10. **Conflict & Recovery** — schema conflicts, contract drift, resolution strategies
11. **Evidence Standard** — CMD + RESULT + OUTPUT format for agent reports
12. **Handoff Protocol** — closeout report, queue state, risks, next tickets
13. **Anti-Patterns** — common mistakes to avoid
14. **Command Reference** — practical CLI snippets
15. **Success Criteria** — lead time, rework rate, merge conflicts, regression-free delivery
16. **Judgment Margin** — runbook as decision support, not a rigid checklist
17. **Reading List** — Codex CLI, LangGraph, AutoGen, CrewAI

> The runbook is tool-agnostic. Examples use Codex CLI, but the principles apply to any agent runner.

## Design Principles

- **Monitor-only** — `orchd` never merges, commits, or pushes. It only reads.
- **Zero dependencies** — just Bash, git, and tmux. No package managers.
- **Append-only logging** — `changes.log` is never modified, only appended to (with automatic rotation at ~10 MB).
- **Tool-agnostic** — the runbook works with any agent runner; Codex CLI is used only as an example.

## Testing

Run the smoke tests:

```bash
./tests/smoke.sh
```

Lint with ShellCheck:

```bash
shellcheck bin/orchd tests/smoke.sh
```

## Contributing

Contributions are welcome! Some areas where help would be appreciated:

- English translation of `orchestrator-runbook.md`
- Additional agent runner examples (beyond Codex CLI)
- More test coverage
- Packaging for Homebrew, AUR, etc.

## License

MIT (see [LICENSE](LICENSE)).
