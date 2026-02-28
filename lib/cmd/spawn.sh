#!/usr/bin/env bash
# lib/cmd/spawn.sh - orchd spawn command
# Creates worktrees and launches AI agents for tasks

cmd_spawn() {
	local target=""
	local runner_override=""
	while (($# > 0)); do
		case "$1" in
		--all)
			target="--all"
			shift
			;;
		--runner | -r)
			shift
			runner_override="${1:-}"
			[[ -n "$runner_override" ]] || die "usage: orchd spawn [--all|<task-id>] [--runner <runner>]"
			shift
			;;
		-h | --help)
			die "usage: orchd spawn <task-id> | orchd spawn --all [--runner <runner>]"
			;;
		*)
			if [[ -z "$target" ]]; then
				target="$1"
				shift
			else
				die "usage: orchd spawn <task-id> | orchd spawn --all [--runner <runner>]"
			fi
			;;
		esac
	done

	require_project

	local runner
	if [[ -n "$runner_override" ]]; then
		runner="$runner_override"
	else
		runner=$(detect_runner)
	fi
	runner_validate "$runner"

	if [[ "$target" == "--all" ]]; then
		_spawn_all_ready "$runner"
	elif [[ -n "$target" ]]; then
		_spawn_single "$target" "$runner"
	else
		die "usage: orchd spawn <task-id> | orchd spawn --all [--runner <runner>]"
	fi
}

_spawn_single() {
	local task_id=$1
	local runner=$2

	task_exists "$task_id" || die "task not found: $task_id"

	local status
	status=$(task_status "$task_id")

	case "$status" in
	running)
		die "task already running: $task_id"
		;;
	merged)
		die "task already merged: $task_id"
		;;
	done)
		printf 'task already done: %s (use orchd merge to integrate)\n' "$task_id"
		return 0
		;;
	esac

	# Check dependencies
	if ! task_is_ready "$task_id"; then
		local deps
		deps=$(task_get "$task_id" "deps" "")
		die "task has unmet dependencies: $task_id (deps: $deps)"
	fi

	local branch="agent-${task_id}"
	local worktree_base
	worktree_base=$(config_get "worktree_dir" ".worktrees")
	local worktree_path="$PROJECT_ROOT/$worktree_base/$branch"

	# Create worktree
	worktree_create "$PROJECT_ROOT" "$branch" "$worktree_path" || {
		die "failed to create worktree for task: $task_id"
	}

	# Ensure agent policy docs are available inside the worktree.
	# These files are created by `orchd init` in the project root, but may be untracked;
	# worktrees only include tracked files. Create them here if missing so the worker can read them.
	ensure_agent_docs "$worktree_path"

	# Build kickoff prompt
	local prompt
	prompt=$(_build_kickoff_prompt "$task_id" "$worktree_path")

	# Record task metadata
	task_set "$task_id" "branch" "$branch"
	task_set "$task_id" "worktree" "$worktree_path"
	task_set "$task_id" "runner" "$runner"
	task_set "$task_id" "status" "running"

	# Launch agent
	if runner_exec "$runner" "$task_id" "$prompt" "$worktree_path"; then
		printf 'spawned: %-20s branch=%-25s runner=%s\n' "$task_id" "$branch" "$runner"
		log_event "INFO" "task spawned: $task_id (branch=$branch runner=$runner)"
	else
		worktree_remove "$PROJECT_ROOT" "$worktree_path"
		rm -f "$(task_dir "$task_id")/session" "$(task_dir "$task_id")/started_at"
		task_set "$task_id" "worktree" ""
		task_set "$task_id" "status" "failed"
		log_event "ERROR" "spawn failed: $task_id (runner=$runner)"
		die "failed to spawn agent for task: $task_id"
	fi
}

_spawn_all_ready() {
	local runner=$1
	local max_parallel
	max_parallel=$(config_get "max_parallel" "3")

	local spawned=0
	local skipped=0
	local running=0

	# Count currently running
	local task_id
	while IFS= read -r task_id; do
		[[ -z "$task_id" ]] && continue
		if [[ "$(task_status "$task_id")" == "running" ]]; then
			running=$((running + 1))
		fi
	done <<<"$(task_list_ids)"

	printf 'scanning tasks... (max_parallel=%s, currently_running=%s)\n\n' "$max_parallel" "$running"

	local failed=0
	while IFS= read -r task_id; do
		[[ -z "$task_id" ]] && continue

		if ((running + spawned >= max_parallel)); then
			printf 'max parallel limit reached (%s), stopping\n' "$max_parallel"
			break
		fi

		if task_is_ready "$task_id"; then
			if (_spawn_single "$task_id" "$runner"); then
				spawned=$((spawned + 1))
			else
				printf 'warning: failed to spawn %s, continuing...\n' "$task_id" >&2
				failed=$((failed + 1))
			fi
		else
			local status
			status=$(task_status "$task_id")
			if [[ "$status" == "pending" ]]; then
				skipped=$((skipped + 1))
			fi
		fi
	done <<<"$(task_list_ids)"

	printf '\nspawned: %d  skipped (waiting for deps): %d  already running: %d' \
		"$spawned" "$skipped" "$running"
	if ((failed > 0)); then
		printf '  failed: %d' "$failed"
	fi
	printf '\n'
}

_build_kickoff_prompt() {
	local task_id=$1
	local worktree_path=$2

	local template_file="$ORCHD_LIB_DIR/../templates/kickoff.prompt"
	if [[ ! -f "$template_file" ]]; then
		# Fallback: minimal prompt
		printf 'TASK: %s\nIMPLEMENT: %s\nACCEPTANCE: %s\n' \
			"$task_id" \
			"$(task_get "$task_id" "description" "")" \
			"$(task_get "$task_id" "acceptance" "")"
		return
	fi

	local prompt
	prompt=$(cat "$template_file")

	local title description acceptance role
	title=$(task_get "$task_id" "title" "$task_id")
	description=$(task_get "$task_id" "description" "Implement $task_id")
	acceptance=$(task_get "$task_id" "acceptance" "All tests pass")
	role=$(task_get "$task_id" "role" "domain")

	prompt=$(replace_token "$prompt" "{task_id}" "$task_id")
	prompt=$(replace_token "$prompt" "{task_title}" "$title")
	prompt=$(replace_token "$prompt" "{task_description}" "$description")
	prompt=$(replace_token "$prompt" "{acceptance_criteria}" "$acceptance")
	prompt=$(replace_token "$prompt" "{agent_role}" "$role")
	prompt=$(replace_token "$prompt" "{worktree_path}" "$worktree_path")

	printf '%s\n' "$prompt"
}
