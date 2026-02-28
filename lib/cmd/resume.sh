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

	# Ensure agent policy docs exist in the worktree for the resumed agent.
	ensure_agent_docs "$worktree"

	local runner
	runner=$(task_get "$task_id" "runner" "")
	if [[ -z "$runner" ]]; then
		runner=$(detect_runner)
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
	prompt=$(_build_continuation_prompt "$task_id" "$worktree" "$attempts_new" "$reason")

	# Reset task status and runner metadata
	task_set "$task_id" "runner" "$runner"
	task_set "$task_id" "status" "running"

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

_rotate_task_logs() {
	local task_id=$1
	local attempt=$2
	local f
	for f in "$LOGS_DIR/${task_id}.log" "$LOGS_DIR/${task_id}.jsonl"; do
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

Notes:
- If you need user input (credentials, decisions, missing requirements), write it to a file named .orchd_needs_input.md at the worktree root and exit.
- Otherwise, fix issues, run relevant tests, commit, and produce TASK_REPORT.md.
EOF
		)
	fi

	local title description acceptance role
	title=$(task_get "$task_id" "title" "$task_id")
	description=$(task_get "$task_id" "description" "Implement $task_id")
	acceptance=$(task_get "$task_id" "acceptance" "All tests pass")
	role=$(task_get "$task_id" "role" "domain")

	prompt=$(replace_token "$prompt" "{task_id}" "$task_id")
	prompt=$(replace_token "$prompt" "{worktree_path}" "$worktree_path")
	prompt=$(replace_token "$prompt" "{task_title}" "$title")
	prompt=$(replace_token "$prompt" "{task_description}" "$description")
	prompt=$(replace_token "$prompt" "{acceptance_criteria}" "$acceptance")
	prompt=$(replace_token "$prompt" "{agent_role}" "$role")
	prompt=$(replace_token "$prompt" "{attempt}" "$attempt")
	prompt=$(replace_token "$prompt" "{resume_reason}" "$reason")

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
