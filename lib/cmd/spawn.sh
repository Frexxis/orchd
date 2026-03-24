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
			printf 'usage: orchd spawn <task-id> | orchd spawn --all [--runner <runner>]\n'
			return 0
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

	local default_runner
	default_runner=$(detect_runner)

	local runner
	if [[ -n "$runner_override" ]]; then
		runner="$runner_override"
	else
		runner=$(swarm_select_runner_for_role "builder" "$default_runner")
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
	merged | split)
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
	worktree_link_python_venv "$worktree_path" || true

	# Build kickoff prompt
	local prompt
	prompt=$(_build_kickoff_prompt "$task_id" "$worktree_path")

	# Record task metadata
	task_set "$task_id" "branch" "$branch"
	task_set "$task_id" "worktree" "$worktree_path"
	task_set "$task_id" "runner" "$runner"
	if [[ -n "$runner_override" ]]; then
		swarm_task_set_route_metadata "$task_id" "builder" "$runner" "$default_runner" "manual runner override for builder role" "false" "$(swarm_role_candidates_csv "builder")"
	else
		swarm_resolve_route "builder" "$default_runner" >/dev/null
		swarm_task_set_route_metadata "$task_id" "builder" "$runner" "$default_runner" "$SWARM_ROUTE_REASON" "$SWARM_ROUTE_FALLBACK_USED" "$SWARM_ROUTE_CANDIDATES"
	fi
	task_prepare_new_attempt "$task_id"

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

	local ready_ids=()
	local task_id status
	while IFS= read -r task_id; do
		[[ -z "$task_id" ]] && continue
		if task_is_ready "$task_id"; then
			ready_ids+=("$task_id")
		else
			status=$(task_status "$task_id")
			if [[ "$status" == "pending" ]]; then
				skipped=$((skipped + 1))
			fi
		fi
	done <<<"$(task_list_ids)"

	local failed=0
	while IFS= read -r task_id; do
		[[ -z "$task_id" ]] && continue

		if ((running + spawned >= max_parallel)); then
			printf 'max parallel limit reached (%s), stopping\n' "$max_parallel"
			break
		fi

		if (_spawn_single "$task_id" "$runner"); then
			spawned=$((spawned + 1))
		else
			printf 'warning: failed to spawn %s, continuing...\n' "$task_id" >&2
			failed=$((failed + 1))
		fi
	done <<<"$(swarm_sort_ready_tasks "${ready_ids[@]}")"

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
	local task_size task_risk task_blast_radius task_file_hints task_recommended_verification
	task_size=$(task_get "$task_id" "size" "")
	task_risk=$(task_get "$task_id" "risk" "")
	task_blast_radius=$(task_get "$task_id" "blast_radius" "")
	task_file_hints=$(task_get "$task_id" "file_hints" "")
	task_recommended_verification=$(task_get "$task_id" "recommended_verification" "")
	[[ -n "$task_size" ]] || task_size="unspecified"
	[[ -n "$task_risk" ]] || task_risk="unspecified"
	[[ -n "$task_blast_radius" ]] || task_blast_radius="unspecified"
	[[ -n "$task_file_hints" ]] || task_file_hints="unspecified"
	[[ -n "$task_recommended_verification" ]] || task_recommended_verification="auto"
	local execution_only no_planning commit_required execution_mode_instructions
	execution_only=$(task_get_bool "$task_id" "execution_only" "false")
	no_planning=$(task_get_bool "$task_id" "no_planning" "false")
	commit_required=$(task_get_bool "$task_id" "commit_required" "false")

	execution_mode_instructions="- Follow normal worker flow: inspect, implement, verify, and report."
	if [[ "$execution_only" == "true" ]] || [[ "$no_planning" == "true" ]] || [[ "$commit_required" == "true" ]]; then
		execution_mode_instructions=""
		if [[ "$execution_only" == "true" ]]; then
			execution_mode_instructions+="- EXECUTION_ONLY is enabled: prioritize concrete code changes and verification over broad exploration."$'\n'
		fi
		if [[ "$no_planning" == "true" ]]; then
			execution_mode_instructions+="- NO_PLANNING is enabled: do not produce plan-only output; perform the implementation steps directly."$'\n'
		fi
		if [[ "$commit_required" == "true" ]]; then
			execution_mode_instructions+="- COMMIT_REQUIRED is enabled: create at least one focused commit before finishing."$'\n'
		fi
		execution_mode_instructions=${execution_mode_instructions%$'\n'}
	fi

	prompt=$(replace_token "$prompt" "{task_id}" "$task_id")
	prompt=$(replace_token "$prompt" "{task_title}" "$title")
	prompt=$(replace_token "$prompt" "{task_description}" "$description")
	prompt=$(replace_token "$prompt" "{acceptance_criteria}" "$acceptance")
	prompt=$(replace_token "$prompt" "{agent_role}" "$role")
	prompt=$(replace_token "$prompt" "{worktree_path}" "$worktree_path")
	prompt=$(replace_token "$prompt" "{execution_only}" "$execution_only")
	prompt=$(replace_token "$prompt" "{no_planning}" "$no_planning")
	prompt=$(replace_token "$prompt" "{commit_required}" "$commit_required")
	prompt=$(replace_token "$prompt" "{execution_mode_instructions}" "$execution_mode_instructions")
	prompt=$(replace_token "$prompt" "{task_size}" "$task_size")
	prompt=$(replace_token "$prompt" "{task_risk}" "$task_risk")
	prompt=$(replace_token "$prompt" "{task_blast_radius}" "$task_blast_radius")
	prompt=$(replace_token "$prompt" "{task_file_hints}" "$task_file_hints")
	prompt=$(replace_token "$prompt" "{task_recommended_verification}" "$task_recommended_verification")

	# Inject memory bank context
	local memory_ctx
	memory_ctx=$(memory_read_context)
	if [[ -z "$memory_ctx" ]]; then
		memory_ctx="(no project memory yet — you are the first agent)"
	fi
	prompt=$(replace_token "$prompt" "{memory_context}" "$memory_ctx")

	printf '%s\n' "$prompt"
}
