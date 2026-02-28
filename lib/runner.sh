#!/usr/bin/env bash
# lib/runner.sh - Multi-runner adapter system
# Supports: codex, claude, opencode, custom
# Sourced by bin/orchd — do not execute directly.

# --- Runner detection ---

detect_runner() {
	local configured
	configured=$(config_get "worker.runner" "")
	if [[ -z "$configured" ]]; then
		# Backward compatibility: old configs stored this under [orchestrator] or root.
		configured=$(config_get "orchestrator.runner" "")
	fi
	if [[ -z "$configured" ]]; then
		configured=$(config_get "runner" "")
	fi

	if [[ -n "$configured" ]] && [[ "$configured" != "auto" ]]; then
		printf '%s\n' "$configured"
		return 0
	fi

	# Auto-detect in priority order
	if command -v codex >/dev/null 2>&1; then
		printf 'codex\n'
	elif command -v claude >/dev/null 2>&1; then
		printf 'claude\n'
	elif command -v opencode >/dev/null 2>&1; then
		printf 'opencode\n'
	elif command -v aider >/dev/null 2>&1; then
		printf 'aider\n'
	else
		printf 'none\n'
	fi
}

runner_validate() {
	local runner=$1
	case "$runner" in
	codex | claude | opencode | aider | custom)
		return 0
		;;
	none)
		die "no supported AI runner found. Install one of: codex, claude, opencode, aider"
		;;
	*)
		die "unsupported runner: $runner (supported: codex, claude, opencode, aider, custom)"
		;;
	esac
}

# --- Runner execution ---
# Each runner adapter builds and executes the agent command inside a tmux session.

runner_exec() {
	local runner=$1
	local task_id=$2
	local prompt=$3
	local worktree=$4
	local session_name="orchd-agent-${task_id}"

	log_event "INFO" "spawning agent: runner=$runner task=$task_id worktree=$worktree"

	local cmd
	case "$runner" in
	codex)
		cmd=$(_runner_cmd_codex "$prompt" "$worktree" "$task_id")
		;;
	claude)
		cmd=$(_runner_cmd_claude "$prompt" "$worktree" "$task_id")
		;;
	opencode)
		cmd=$(_runner_cmd_opencode "$prompt" "$worktree" "$task_id")
		;;
	aider)
		cmd=$(_runner_cmd_aider "$prompt" "$worktree" "$task_id")
		;;
	custom)
		cmd=$(_runner_cmd_custom "$prompt" "$worktree" "$task_id")
		;;
	esac

	# Launch in tmux
	if tmux has-session -t "$session_name" 2>/dev/null; then
		log_event "WARN" "agent session already exists: $session_name"
		return 1
	fi

	tmux new -d -s "$session_name" "$cmd"
	task_set "$task_id" "session" "$session_name"
	task_set "$task_id" "started_at" "$(now_iso)"
	log_event "INFO" "agent started: session=$session_name"
	return 0
}

# --- Runner-specific command builders ---

_runner_cmd_codex() {
	local prompt=$1
	local worktree=$2
	local task_id=$3
	local log_file="$LOGS_DIR/${task_id}.jsonl"
	local codex_bin
	codex_bin=$(config_get "codex_bin" "codex")

	printf '%s exec %s -C %s --json > %s 2>&1; echo "ORCHD_EXIT:$?" >> %s' \
		"$codex_bin" \
		"$(printf '%q' "$prompt")" \
		"$(printf '%q' "$worktree")" \
		"$(printf '%q' "$log_file")" \
		"$(printf '%q' "$log_file")"
}

_runner_cmd_claude() {
	local prompt=$1
	local worktree=$2
	local task_id=$3
	local log_file="$LOGS_DIR/${task_id}.log"
	local claude_bin
	claude_bin=$(config_get "claude_bin" "claude")

	# claude CLI: claude -p "prompt" --workdir <dir> --allowedTools ...
	printf 'cd %s && %s -p %s --output-format text > %s 2>&1; echo "ORCHD_EXIT:$?" >> %s' \
		"$(printf '%q' "$worktree")" \
		"$claude_bin" \
		"$(printf '%q' "$prompt")" \
		"$(printf '%q' "$log_file")" \
		"$(printf '%q' "$log_file")"
}

_runner_cmd_opencode() {
	local prompt=$1
	local worktree=$2
	local task_id=$3
	local log_file="$LOGS_DIR/${task_id}.log"

	printf 'cd %s && opencode -p %s > %s 2>&1; echo "ORCHD_EXIT:$?" >> %s' \
		"$(printf '%q' "$worktree")" \
		"$(printf '%q' "$prompt")" \
		"$(printf '%q' "$log_file")" \
		"$(printf '%q' "$log_file")"
}

_runner_cmd_aider() {
	local prompt=$1
	local worktree=$2
	local task_id=$3
	local log_file="$LOGS_DIR/${task_id}.log"

	printf 'cd %s && aider --message %s --yes > %s 2>&1; echo "ORCHD_EXIT:$?" >> %s' \
		"$(printf '%q' "$worktree")" \
		"$(printf '%q' "$prompt")" \
		"$(printf '%q' "$log_file")" \
		"$(printf '%q' "$log_file")"
}

_runner_cmd_custom() {
	local prompt=$1
	local worktree=$2
	local task_id=$3
	local log_file="$LOGS_DIR/${task_id}.log"
	local custom_cmd
	custom_cmd=$(config_get "custom_runner_cmd" "")

	if [[ -z "$custom_cmd" ]]; then
		die "custom runner requires 'custom_runner_cmd' in .orchd.toml"
	fi

	# Replace placeholders: {prompt}, {worktree}, {task_id}, {log_file}
	custom_cmd=$(replace_token "$custom_cmd" "{prompt}" "$(printf '%q' "$prompt")")
	custom_cmd=$(replace_token "$custom_cmd" "{worktree}" "$(printf '%q' "$worktree")")
	custom_cmd=$(replace_token "$custom_cmd" "{task_id}" "$(printf '%q' "$task_id")")
	custom_cmd=$(replace_token "$custom_cmd" "{log_file}" "$(printf '%q' "$log_file")")

	printf '%s' "$custom_cmd"
}

# --- Agent session management ---

runner_is_alive() {
	local task_id=$1
	local session_name
	session_name=$(task_get "$task_id" "session" "")
	[[ -n "$session_name" ]] && tmux has-session -t "$session_name" 2>/dev/null
}

runner_stop() {
	local task_id=$1
	local session_name
	session_name=$(task_get "$task_id" "session" "")
	if [[ -n "$session_name" ]]; then
		tmux kill-session -t "$session_name" 2>/dev/null || true
		log_event "INFO" "agent stopped: $session_name"
	fi
}

runner_attach() {
	local task_id=$1
	local session_name
	session_name=$(task_get "$task_id" "session" "")
	if [[ -z "$session_name" ]]; then
		die "no session found for task: $task_id"
	fi
	if ! tmux has-session -t "$session_name" 2>/dev/null; then
		die "session not running: $session_name"
	fi
	tmux attach -t "$session_name"
}

runner_exit_code() {
	local task_id=$1
	local runner
	runner=$(task_get "$task_id" "runner" "")

	local file_candidates=()
	if [[ "$runner" == "codex" ]]; then
		file_candidates+=("$LOGS_DIR/${task_id}.jsonl")
	fi
	file_candidates+=("$LOGS_DIR/${task_id}.log" "$LOGS_DIR/${task_id}.jsonl")

	local file exit_code
	for file in "${file_candidates[@]}"; do
		[[ -f "$file" ]] || continue
		exit_code=$(awk -F ':' '/^ORCHD_EXIT:/ { code = $2 } END { gsub(/^[[:space:]]+|[[:space:]]+$/, "", code); if (code != "") print code }' "$file")
		if [[ -n "$exit_code" ]]; then
			printf '%s\n' "$exit_code"
			return 0
		fi
	done

	return 1
}
