# orchd

Minimal tools + runbook for multi-agent engineering orchestration.

This repo contains:

- `orchestrator-runbook.md`: practical orchestration guidance (tool-agnostic; Codex CLI examples).
- `bin/orchd`: a tiny tmux-based monitor that periodically fetches a repo and records branch/ref changes.

## Install

```bash
chmod +x bin/orchd
mkdir -p ~/.local/bin
ln -sf "$PWD/bin/orchd" ~/.local/bin/orchd
```

## Usage

Start a monitor loop (monitor-only; does not merge/commit/push):

```bash
orchd start /path/to/repo 30
```

Attach:

```bash
orchd attach orchd-<repo>
```

Stop:

```bash
orchd stop orchd-<repo>
```

See also:

```bash
orchd --help
```

## Notes

- `orchd` writes state under `~/.orchd/<session>/`.
- The runbook recommends keeping secrets out of prompts; use env vars/secret managers.

## License

MIT (see `LICENSE`).
