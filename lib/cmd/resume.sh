#!/usr/bin/env bash
# lib/cmd/resume.sh - orchd resume command
# Re-launches an agent for an existing task/worktree with a continuation prompt.

cmd_resume() {
	local task_id="${1:-}"
	shift || true
	local reason="${*:-}"

	require_project

	if [[ -z "$task_id" ]]; then
		die "usage: orchd resume <task-id> [reason...]"
	fi

	_resume_single "$task_id" "${reason:-manual resume}"
}

_resume_single() {
	local task_id=$1
	local reason=${2:-resume}

	task_exists "$task_id" || die "task not found: $task_id"

	local status
	status=$(task_status "$task_id")
	case "$status" in
	merged)
		die "task already merged: $task_id"
		;;
	split)
		die "task already split into follow-up tasks: $task_id"
		;;
	pending)
		die "task is pending: $task_id (use orchd spawn $task_id)"
		;;
	running)
		if runner_is_alive "$task_id"; then
			die "task still running: $task_id"
		fi
		;;
	failed | needs_input | done | conflict)
		# ok
		;;
	*)
		# unknown custom status - allow resume if worktree exists
		;;
	esac

	local worktree
	worktree=$(task_get "$task_id" "worktree" "")
	[[ -n "$worktree" ]] || die "no worktree found for task: $task_id"
	[[ -d "$worktree" ]] || die "worktree missing: $worktree"

	# Always clear stale tmux sessions before opening a new attempt.
	_resume_cleanup_stale_session "$task_id"

	# Ensure agent policy docs exist in the worktree for the resumed agent.
	ensure_agent_docs "$worktree"
	worktree_link_python_venv "$worktree" || true

	local default_runner
	default_runner=$(detect_runner)

	local runner
	local resume_is_recovery=false
	local existing_runner
	local original_runner
	local recovery_default_runner
	existing_runner=$(task_get "$task_id" "runner" "")
	original_runner=$(task_get "$task_id" "original_runner" "")
	if [[ -z "$(task_get "$task_id" "original_runner" "")" ]] && [[ -n "$existing_runner" ]]; then
		task_set "$task_id" "original_runner" "$existing_runner"
		original_runner="$existing_runner"
	fi

	if [[ "$status" == "failed" || "$status" == "conflict" || "$status" == "needs_input" ]] || [[ -n "$(task_get "$task_id" "failure_class" "")" ]]; then
		resume_is_recovery=true
	fi

	if [[ "$resume_is_recovery" == "true" ]]; then
		recovery_default_runner="$default_runner"
		if [[ -n "$existing_runner" ]]; then
			recovery_default_runner="$existing_runner"
		fi
		recovery_policy_for_class "$task_id" "$(task_get "$task_id" "failure_class" "")" >/dev/null
		runner=$(recovery_select_runner "$task_id" "$recovery_default_runner" "$existing_runner")
	else
		runner="$existing_runner"
		if [[ -z "$runner" && -n "$original_runner" ]]; then
			runner="$original_runner"
		fi
		if [[ -z "$runner" ]]; then
			runner="$default_runner"
		fi
	fi

	if [[ "$runner" != "none" ]]; then
		runner_validate "$runner"
	else
		die "no supported AI runner found (needed to resume task: $task_id)"
	fi

	# Attempt counter: rotate existing logs as the previous attempt,
	# then increment for the new run.
	local attempts_current attempts_new
	attempts_current=$(task_get "$task_id" "attempts" "0")
	if ! [[ "$attempts_current" =~ ^[0-9]+$ ]]; then
		attempts_current=0
	fi

	# Rotate existing logs to preserve history (attempt index of the run that produced them)
	_rotate_task_logs "$task_id" "$attempts_current"

	attempts_new=$((attempts_current + 1))
	task_set "$task_id" "attempts" "$attempts_new"
	task_set "$task_id" "last_resume_reason" "$reason"
	task_set "$task_id" "last_resume_at" "$(now_iso)"

	# Build continuation prompt
	local prompt
	prompt=$(_build_resume_prompt "$task_id" "$worktree" "$attempts_new" "$reason" "$runner")

	# Reset task status and runner metadata
	task_set "$task_id" "last_runner" "$runner"
	task_set "$task_id" "runner" "$runner"
	if [[ "$resume_is_recovery" == "true" ]]; then
		swarm_task_set_route_metadata "$task_id" "recovery" "$runner" "$recovery_default_runner" "${SWARM_ROUTE_REASON:-}" "${SWARM_ROUTE_FALLBACK_USED:-false}" "${SWARM_ROUTE_CANDIDATES:-}"
	fi
	task_prepare_new_attempt "$task_id"

	# Launch agent
	if runner_exec "$runner" "$task_id" "$prompt" "$worktree"; then
		printf 'resumed: %-20s attempt=%-3s runner=%s\n' "$task_id" "$attempts_new" "$runner"
		log_event "INFO" "task resumed: $task_id (attempt=$attempts_new runner=$runner)"
	else
		task_set "$task_id" "status" "failed"
		log_event "ERROR" "resume failed: $task_id (runner=$runner)"
		die "failed to resume agent for task: $task_id"
	fi
}

_build_resume_prompt() {
	local task_id=$1
	local worktree_path=$2
	local attempt=$3
	local reason=$4
	local selected_runner_override=${5:-}
	local status
	status=$(task_status "$task_id")
	if [[ "$status" == "failed" || "$status" == "conflict" || "$status" == "needs_input" ]] || [[ -n "$(task_get "$task_id" "failure_class" "")" ]]; then
		_build_recovery_prompt "$task_id" "$worktree_path" "$attempt" "$reason" "$selected_runner_override"
		return 0
	fi
	_build_continuation_prompt "$task_id" "$worktree_path" "$attempt" "$reason"
}

_resume_cleanup_stale_session() {
	local task_id=$1
	if ! runner_has_session "$task_id"; then
		return 0
	fi
	local session_name
	session_name=$(runner_session_name "$task_id")
	runner_stop "$task_id"
	log_event "INFO" "resume preflight: cleaned stale session for $task_id ($session_name)"
}

_rotate_task_logs() {
	local task_id=$1
	local attempt=$2
	local f
	for f in "$LOGS_DIR/${task_id}.log" "$LOGS_DIR/${task_id}.jsonl" "$LOGS_DIR/${task_id}.exit"; do
		[[ -f "$f" ]] || continue
		local ext
		ext=${f##*.}
		mv "$f" "$LOGS_DIR/${task_id}.attempt${attempt}.${ext}" 2>/dev/null || true
	done
}

_build_continuation_prompt() {
	local task_id=$1
	local worktree_path=$2
	local attempt=$3
	local reason=$4

	local template_file="$ORCHD_LIB_DIR/../templates/continue.prompt"
	local prompt
	if [[ -f "$template_file" ]]; then
		prompt=$(cat "$template_file")
	else
		prompt=$(
			cat <<'EOF'
AGENT: {agent_role}
MODE: WORKER
MUST_READ: AGENTS.md, WORKER.md
TASK: {task_id}
WORKTREE: {worktree_path}

[ORCHD SYSTEM DIRECTIVE - CONTINUATION]

Continue the task. You previously attempted this task and it is not complete.

Reason:
{resume_reason}

Attempt:
{attempt}

Execution mode:
- execution_only: {execution_only}
- no_planning: {no_planning}
- commit_required: {commit_required}

Task metadata:
- size: {task_size}
- risk: {task_risk}
- blast_radius: {task_blast_radius}
- file_hints: {task_file_hints}
- recommended_verification: {task_recommended_verification}

{execution_mode_instructions}

Notes:
- If you need user input (credentials, decisions, missing requirements), write a structured payload to .orchd_needs_input.json with keys code, summary, question, blocking, options, then exit.
- You may also add .orchd_needs_input.md for extra context.
- Otherwise, fix issues, run relevant tests, commit, and produce TASK_REPORT.md.
EOF
		)
	fi

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
	prompt=$(replace_token "$prompt" "{worktree_path}" "$worktree_path")
	prompt=$(replace_token "$prompt" "{task_title}" "$title")
	prompt=$(replace_token "$prompt" "{task_description}" "$description")
	prompt=$(replace_token "$prompt" "{acceptance_criteria}" "$acceptance")
	prompt=$(replace_token "$prompt" "{agent_role}" "$role")
	prompt=$(replace_token "$prompt" "{attempt}" "$attempt")
	prompt=$(replace_token "$prompt" "{resume_reason}" "$reason")
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
		memory_ctx="(no project memory yet)"
	fi
	prompt=$(replace_token "$prompt" "{memory_context}" "$memory_ctx")

	# Attach last check summary if present (kept short)
	local check_file
	check_file="$(task_dir "$task_id")/last_check.txt"
	if [[ -f "$check_file" ]]; then
		prompt+=$'\n\nLast check summary:\n'
		prompt+=$(tail -n 120 "$check_file" 2>/dev/null || true)
	fi

	# Attach last agent output tail if present
	local log_file=""
	if [[ -f "$LOGS_DIR/${task_id}.log" ]]; then
		log_file="$LOGS_DIR/${task_id}.log"
	elif [[ -f "$LOGS_DIR/${task_id}.jsonl" ]]; then
		log_file="$LOGS_DIR/${task_id}.jsonl"
	fi
	if [[ -n "$log_file" ]]; then
		prompt+=$'\n\nLast agent output (tail):\n'
		prompt+=$(tail -n 120 "$log_file" 2>/dev/null || true)
	fi

	printf '%s\n' "$prompt"
}

_build_recovery_prompt() {
	local task_id=$1
	local worktree_path=$2
	local attempt=$3
	local reason=$4
	local selected_runner_override=${5:-}
	local template_file="$ORCHD_LIB_DIR/../templates/recovery.prompt"
	local prompt
	if [[ -f "$template_file" ]]; then
		prompt=$(cat "$template_file")
	else
		prompt=$(
			cat <<'EOF'
AGENT: {agent_role}
MODE: WORKER
MUST_READ: AGENTS.md, WORKER.md
TASK: {task_id}
WORKTREE: {worktree_path}

[ORCHD SYSTEM DIRECTIVE - RECOVERY]

Recover this task using the exact failure evidence below.

Reason:
{resume_reason}

Attempt:
{attempt}

Recovery context:
- failure_class: {failure_class}
- failure_summary: {failure_summary}
- recovery_policy: {recovery_policy}
- recovery_next_action: {recovery_next_action}
- recovery_policy_reason: {recovery_policy_reason}
- previous_runner: {previous_runner}
- selected_runner: {selected_runner}

Task metadata:
- size: {task_size}
- risk: {task_risk}
- blast_radius: {task_blast_radius}
- file_hints: {task_file_hints}
- recommended_verification: {task_recommended_verification}

Instructions:
- Fix the concrete failure instead of rewriting unrelated areas.
- Keep changes focused and minimal.
- If the task is too large or ambiguous to finish safely, create a follow-up split plan and document the exact boundary in TASK_REPORT.md.
- If you need user input (credentials, decisions, missing requirements), write .orchd_needs_input.json and exit.
- Otherwise, implement the fix, run relevant checks, and produce TASK_REPORT.md.
EOF
		)
	fi

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

	local failure_class failure_summary recovery_policy recovery_next_action recovery_policy_reason previous_runner selected_runner
	failure_class=$(task_get "$task_id" "failure_class" "scope_confusion")
	failure_summary=$(task_get "$task_id" "failure_summary" "")
	[[ -n "$failure_summary" ]] || failure_summary=$(recovery_failure_summary "$failure_class")
	recovery_policy=$(task_get "$task_id" "recovery_policy" "retry_same_runner")
	recovery_next_action=$(task_get "$task_id" "recovery_next_action" "resume_with_targeted_fix")
	recovery_policy_reason=$(task_get "$task_id" "recovery_policy_reason" "")
	previous_runner=$(task_get "$task_id" "runner" "")
	selected_runner="$selected_runner_override"
	if [[ -z "$selected_runner" ]]; then
		selected_runner=$(task_get "$task_id" "last_runner" "")
	fi
	[[ -n "$selected_runner" ]] || selected_runner="$previous_runner"

	prompt=$(replace_token "$prompt" "{task_id}" "$task_id")
	prompt=$(replace_token "$prompt" "{worktree_path}" "$worktree_path")
	prompt=$(replace_token "$prompt" "{task_title}" "$title")
	prompt=$(replace_token "$prompt" "{task_description}" "$description")
	prompt=$(replace_token "$prompt" "{acceptance_criteria}" "$acceptance")
	prompt=$(replace_token "$prompt" "{agent_role}" "$role")
	prompt=$(replace_token "$prompt" "{attempt}" "$attempt")
	prompt=$(replace_token "$prompt" "{resume_reason}" "$reason")
	prompt=$(replace_token "$prompt" "{failure_class}" "$failure_class")
	prompt=$(replace_token "$prompt" "{failure_summary}" "$failure_summary")
	prompt=$(replace_token "$prompt" "{recovery_policy}" "$recovery_policy")
	prompt=$(replace_token "$prompt" "{recovery_next_action}" "$recovery_next_action")
	prompt=$(replace_token "$prompt" "{recovery_policy_reason}" "$recovery_policy_reason")
	prompt=$(replace_token "$prompt" "{previous_runner}" "$previous_runner")
	prompt=$(replace_token "$prompt" "{selected_runner}" "$selected_runner")
	prompt=$(replace_token "$prompt" "{task_size}" "$task_size")
	prompt=$(replace_token "$prompt" "{task_risk}" "$task_risk")
	prompt=$(replace_token "$prompt" "{task_blast_radius}" "$task_blast_radius")
	prompt=$(replace_token "$prompt" "{task_file_hints}" "$task_file_hints")
	prompt=$(replace_token "$prompt" "{task_recommended_verification}" "$task_recommended_verification")

	local memory_ctx
	memory_ctx=$(memory_read_context)
	if [[ -z "$memory_ctx" ]]; then
		memory_ctx="(no project memory yet)"
	fi
	prompt=$(replace_token "$prompt" "{memory_context}" "$memory_ctx")

	local check_file
	check_file="$(task_dir "$task_id")/last_check.txt"
	if [[ -f "$check_file" ]]; then
		prompt+=$'\n\nLast check summary:\n'
		prompt+=$(tail -n 120 "$check_file" 2>/dev/null || true)
	fi

	local log_file=""
	if [[ -f "$LOGS_DIR/${task_id}.log" ]]; then
		log_file="$LOGS_DIR/${task_id}.log"
	elif [[ -f "$LOGS_DIR/${task_id}.jsonl" ]]; then
		log_file="$LOGS_DIR/${task_id}.jsonl"
	fi
	if [[ -n "$log_file" ]]; then
		prompt+=$'\n\nLast agent output (tail):\n'
		prompt+=$(tail -n 120 "$log_file" 2>/dev/null || true)
	fi

	printf '%s\n' "$prompt"
}
