#!/usr/bin/env bash
# lib/cmd/init.sh - orchd init command
# Creates .orchd.toml and .orchd/ directory in the current project

cmd_init() {
	local project_dir="${1:-$PWD}"
	local description="${2:-}"

	[[ -d "$project_dir/.git" ]] || die "not a git repository: $project_dir"

	if [[ -f "$project_dir/.orchd.toml" ]]; then
		die "already initialized: $project_dir/.orchd.toml exists"
	fi

	# Detect available runner
	local runner="auto"
	if command -v codex >/dev/null 2>&1; then
		runner="codex"
	elif command -v claude >/dev/null 2>&1; then
		runner="claude"
	elif command -v opencode >/dev/null 2>&1; then
		runner="opencode"
	elif command -v aider >/dev/null 2>&1; then
		runner="aider"
	fi

	# Detect base branch
	local base_branch="main"
	if git -C "$project_dir" rev-parse --verify main >/dev/null 2>&1; then
		base_branch="main"
	elif git -C "$project_dir" rev-parse --verify master >/dev/null 2>&1; then
		base_branch="master"
	fi

	# Generate config
	cat >"$project_dir/.orchd.toml" <<EOF
# orchd - autonomous AI orchestration config
# Docs: https://github.com/Frexxis/orchd

[project]
name = "$(basename "$project_dir")"
description = "$description"
base_branch = "$base_branch"

[orchestrator]
runner = "$runner"
max_parallel = 3
worktree_dir = ".worktrees"
monitor_interval = 30

[quality]
lint_cmd = ""
test_cmd = ""
build_cmd = ""

# [runners.codex]
# codex_bin = "codex"
#
# [runners.claude]
# claude_bin = "claude"
#
# [runners.custom]
# custom_runner_cmd = "my-agent --prompt {prompt} --dir {worktree}"
EOF

	# Create state directory
	mkdir -p "$project_dir/.orchd"/{tasks,logs}

	# Add .orchd/ to .gitignore if not already there
	if [[ -f "$project_dir/.gitignore" ]]; then
		if ! grep -qx '.orchd/' "$project_dir/.gitignore" 2>/dev/null; then
			printf '\n# orchd state (local)\n.orchd/\n.worktrees/\n' >>"$project_dir/.gitignore"
		fi
	else
		printf '# orchd state (local)\n.orchd/\n.worktrees/\n' >"$project_dir/.gitignore"
	fi

	printf 'initialized orchd in %s\n' "$project_dir"
	printf '  config:  .orchd.toml\n'
	printf '  state:   .orchd/\n'
	printf '  runner:  %s\n' "$runner"
	printf '  branch:  %s\n' "$base_branch"
	printf '\nnext steps:\n'
	printf '  1. edit .orchd.toml (set description, lint/test commands)\n'
	printf '  2. orchd plan "build a REST API with auth and tests"\n'
	printf '  3. orchd spawn --all\n'
}
