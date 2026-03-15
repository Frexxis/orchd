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
	local runner
	local prev_project_root="${PROJECT_ROOT:-}"
	PROJECT_ROOT="$project_dir"
	runner=$(detect_runner)
	if [[ -n "$prev_project_root" ]]; then
		PROJECT_ROOT="$prev_project_root"
	else
		unset PROJECT_ROOT
	fi

	local project_name
	project_name=$(basename "$project_dir")

	# Escape user-controlled values before writing TOML
	local safe_project_name safe_description
	safe_project_name=${project_name//\\/\\\\}
	safe_project_name=${safe_project_name//"/\\"/}
	safe_project_name=${safe_project_name//$'\n'/\\n}
	safe_project_name=${safe_project_name//$'\r'/\\r}

	safe_description=${description//\\/\\\\}
	safe_description=${safe_description//"/\\"/}
	safe_description=${safe_description//$'\n'/\\n}
	safe_description=${safe_description//$'\r'/\\r}

	# Detect base branch
	local base_branch=""
	if git -C "$project_dir" rev-parse --verify main >/dev/null 2>&1; then
		base_branch="main"
	elif git -C "$project_dir" rev-parse --verify master >/dev/null 2>&1; then
		base_branch="master"
	else
		# Handles freshly initialized repos (no commits yet).
		base_branch=$(git -C "$project_dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
		[[ -n "$base_branch" ]] || base_branch="main"
	fi

	# Generate config
	cat >"$project_dir/.orchd.toml" <<EOF
# orchd - autonomous AI orchestration config
# Docs: https://github.com/Frexxis/orchd

[project]
name = "$safe_project_name"
description = "$safe_description"
base_branch = "$base_branch"

[orchestrator]
max_parallel = 3
worktree_dir = ".worktrees"
monitor_interval = 30
board_refresh = 5
runner = "auto"
autopilot_mode = "ai"
supervisor_poll = 30
continue_delay = 1
max_iterations = 0
max_stagnation = 8
session_mode = "auto"
idle_timeout = 45
reminder_cooldown = 20
max_reminders = 8
fallback_on_inject_failure = true

[worker]
runner = "$runner"

[quality]
lint_cmd = ""
test_cmd = ""
build_cmd = ""

[ideate]
max_ideas = 5
cooldown_seconds = 30
max_cycles = 20
max_consecutive_failures = 3

	# [runners.codex]
	# codex_bin = "codex"
	# codex_flags = "--dangerously-bypass-approvals-and-sandbox"
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
		if ! grep -qx 'TASK_REPORT.md' "$project_dir/.gitignore" 2>/dev/null; then
			printf '\n# orchd agent artifacts (local)\nTASK_REPORT.md\n' >>"$project_dir/.gitignore"
		fi
		if ! grep -qx '.orchd_needs_input.json' "$project_dir/.gitignore" 2>/dev/null; then
			printf '.orchd_needs_input.json\n' >>"$project_dir/.gitignore"
		fi
		if ! grep -qx '.orchd_needs_input.md' "$project_dir/.gitignore" 2>/dev/null; then
			printf '.orchd_needs_input.md\n' >>"$project_dir/.gitignore"
		fi
		if ! grep -qx 'BLOCKER.md' "$project_dir/.gitignore" 2>/dev/null; then
			printf 'BLOCKER.md\n' >>"$project_dir/.gitignore"
		fi
	else
		printf '# orchd state (local)\n.orchd/\n.worktrees/\n\n# orchd agent artifacts (local)\nTASK_REPORT.md\n.orchd_needs_input.json\n.orchd_needs_input.md\nBLOCKER.md\n' >"$project_dir/.gitignore"
	fi

	# Create agent policy docs if missing
	ensure_agent_docs "$project_dir"

	printf 'initialized orchd in %s\n' "$project_dir"
	printf '  config:  .orchd.toml\n'
	printf '  state:   .orchd/\n'
	printf '  runner:  %s\n' "$runner"
	printf '  branch:  %s\n' "$base_branch"
	if ! git -C "$project_dir" rev-parse --verify HEAD >/dev/null 2>&1; then
		printf '\nwarning: git repo has no commits yet; orchd worktrees require at least 1 commit\n'
		printf '  run: git commit --allow-empty -m "init"\n'
	fi
	printf '\nnext steps:\n'
	printf '  1. edit .orchd.toml (set description, lint/test commands)\n'
	printf '  2. orchd plan "build a REST API with auth and tests"\n'
	printf '  3. orchd spawn --all\n'
}
