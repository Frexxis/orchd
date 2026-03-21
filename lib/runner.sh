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
	local exit_file="$LOGS_DIR/${task_id}.exit"
	local prompt_file="$LOGS_DIR/${task_id}.prompt.txt"

	log_event "INFO" "spawning agent: runner=$runner task=$task_id worktree=$worktree"

	# Persist the prompt to a file so the tmux shell never has to parse
	# multi-line shell-escaped strings (POSIX sh can't handle bash $'..' quoting).
	# Newlines are preserved when we load the file into a variable at runtime.
	printf '%s' "$prompt" >"$prompt_file"

	local cmd
	case "$runner" in
	codex)
		cmd=$(_runner_cmd_codex "$prompt_file" "$worktree" "$task_id")
		;;
	claude)
		cmd=$(_runner_cmd_claude "$prompt_file" "$worktree" "$task_id")
		;;
	opencode)
		cmd=$(_runner_cmd_opencode "$prompt_file" "$worktree" "$task_id")
		;;
	aider)
		cmd=$(_runner_cmd_aider "$prompt_file" "$worktree" "$task_id")
		;;
	custom)
		cmd=$(_runner_cmd_custom "$prompt_file" "$worktree" "$task_id")
		;;
	esac

	# Launch in tmux
	if tmux has-session -t "$session_name" 2>/dev/null; then
		log_event "WARN" "agent session already exists: $session_name"
		return 1
	fi

	# Ensure stale markers from previous attempts don't make the session appear finished.
	rm -f "$exit_file" 2>/dev/null || true

	tmux new -d -s "$session_name" "$cmd"
	task_set "$task_id" "session" "$session_name"
	task_set "$task_id" "started_at" "$(now_iso)"
	log_event "INFO" "agent started: session=$session_name"
	return 0
}

# --- Runner-specific command builders ---

_runner_cmd_codex() {
	local prompt_file=$1
	local worktree=$2
	local task_id=$3
	local log_file="$LOGS_DIR/${task_id}.jsonl"
	local exit_file="$LOGS_DIR/${task_id}.exit"
	local codex_bin
	codex_bin=$(config_get "codex_bin" "codex")
	local codex_flags
	# Default enables write access in isolated worktrees.
	# Override in .orchd.toml with `codex_flags = "..."` (prefer [runners.codex]).
	codex_flags=$(config_get "codex_flags" "--dangerously-bypass-approvals-and-sandbox")

	printf 'cd %s && PROMPT="$(cat %s)" && %s %s exec "$PROMPT" -C %s --json > %s 2>&1; rc=$?; printf "ORCHD_EXIT:%%s\\n" "$rc" >> %s; printf "%%s\\n" "$rc" > %s' \
		"$(printf '%q' "$worktree")" \
		"$(printf '%q' "$prompt_file")" \
		"$codex_bin" \
		"$codex_flags" \
		"$(printf '%q' "$worktree")" \
		"$(printf '%q' "$log_file")" \
		"$(printf '%q' "$log_file")" \
		"$(printf '%q' "$exit_file")"
}

_runner_cmd_claude() {
	local prompt_file=$1
	local worktree=$2
	local task_id=$3
	local log_file="$LOGS_DIR/${task_id}.log"
	local exit_file="$LOGS_DIR/${task_id}.exit"
	local claude_bin
	claude_bin=$(config_get "claude_bin" "claude")

	# claude CLI: claude -p "prompt" --workdir <dir> --allowedTools ...
	printf 'cd %s && PROMPT="$(cat %s)" && %s -p "$PROMPT" --output-format text > %s 2>&1; rc=$?; printf "ORCHD_EXIT:%%s\\n" "$rc" >> %s; printf "%%s\\n" "$rc" > %s' \
		"$(printf '%q' "$worktree")" \
		"$(printf '%q' "$prompt_file")" \
		"$claude_bin" \
		"$(printf '%q' "$log_file")" \
		"$(printf '%q' "$log_file")" \
		"$(printf '%q' "$exit_file")"
}

_runner_cmd_opencode() {
	local prompt_file=$1
	local worktree=$2
	local task_id=$3
	local log_file="$LOGS_DIR/${task_id}.log"
	local exit_file="$LOGS_DIR/${task_id}.exit"
	local opencode_bin
	opencode_bin=$(config_get "opencode_bin" "opencode")

	printf 'cd %s && PROMPT="$(cat %s)" && %s -p "$PROMPT" > %s 2>&1; rc=$?; printf "ORCHD_EXIT:%%s\\n" "$rc" >> %s; printf "%%s\\n" "$rc" > %s' \
		"$(printf '%q' "$worktree")" \
		"$(printf '%q' "$prompt_file")" \
		"$opencode_bin" \
		"$(printf '%q' "$log_file")" \
		"$(printf '%q' "$log_file")" \
		"$(printf '%q' "$exit_file")"
}

_runner_cmd_aider() {
	local prompt_file=$1
	local worktree=$2
	local task_id=$3
	local log_file="$LOGS_DIR/${task_id}.log"
	local exit_file="$LOGS_DIR/${task_id}.exit"

	printf 'cd %s && PROMPT="$(cat %s)" && aider --message "$PROMPT" --yes > %s 2>&1; rc=$?; printf "ORCHD_EXIT:%%s\\n" "$rc" >> %s; printf "%%s\\n" "$rc" > %s' \
		"$(printf '%q' "$worktree")" \
		"$(printf '%q' "$prompt_file")" \
		"$(printf '%q' "$log_file")" \
		"$(printf '%q' "$log_file")" \
		"$(printf '%q' "$exit_file")"
}

_runner_cmd_custom() {
	local prompt_file=$1
	local worktree=$2
	local task_id=$3
	local log_file="$LOGS_DIR/${task_id}.log"
	local exit_file="$LOGS_DIR/${task_id}.exit"
	local custom_cmd
	custom_cmd=$(config_get "custom_runner_cmd" "")

	if [[ -z "$custom_cmd" ]]; then
		die "custom runner requires 'custom_runner_cmd' in .orchd.toml"
	fi

	# Replace placeholders: {prompt}, {prompt_file}, {worktree}, {task_id}, {log_file}
	# - {prompt} expands to a quoted shell variable ($PROMPT) that contains newlines safely.
	# - {prompt_file} expands to a quoted shell variable ($PROMPT_FILE).
	custom_cmd=$(replace_token "$custom_cmd" "{prompt}" '"$PROMPT"')
	custom_cmd=$(replace_token "$custom_cmd" "{prompt_file}" '"$PROMPT_FILE"')
	custom_cmd=$(replace_token "$custom_cmd" "{worktree}" "$(printf '%q' "$worktree")")
	custom_cmd=$(replace_token "$custom_cmd" "{task_id}" "$(printf '%q' "$task_id")")
	custom_cmd=$(replace_token "$custom_cmd" "{log_file}" "$(printf '%q' "$log_file")")

	printf 'cd %s && PROMPT_FILE=%s && PROMPT="$(cat %s)" && %s; rc=$?; printf "ORCHD_EXIT:%%s\\n" "$rc" >> %s 2>/dev/null || true; printf "%%s\\n" "$rc" > %s' \
		"$(printf '%q' "$worktree")" \
		"$(printf '%q' "$prompt_file")" \
		"$(printf '%q' "$prompt_file")" \
		"$custom_cmd" \
		"$(printf '%q' "$log_file")" \
		"$(printf '%q' "$exit_file")"
}

# --- Agent session management ---

runner_session_name() {
	local task_id=$1
	task_get "$task_id" "session" ""
}

runner_has_session() {
	local task_id=$1
	local session_name
	session_name=$(runner_session_name "$task_id")
	[[ -n "$session_name" ]] && tmux has-session -t "$session_name" 2>/dev/null
}

runner_is_alive() {
	local task_id=$1
	local exit_file="$LOGS_DIR/${task_id}.exit"
	# If we already have an exit marker, treat as not alive even if tmux remains.
	if [[ -f "$exit_file" ]]; then
		return 1
	fi
	runner_has_session "$task_id"
}

runner_stop() {
	local task_id=$1
	local session_name
	session_name=$(runner_session_name "$task_id")
	if [[ -n "$session_name" ]] && tmux has-session -t "$session_name" 2>/dev/null; then
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
	local exit_file="$LOGS_DIR/${task_id}.exit"
	if [[ -f "$exit_file" ]]; then
		local code
		code=$(cat "$exit_file" 2>/dev/null || true)
		code=$(printf '%s' "$code" | tr -d '[:space:]')
		if [[ -n "$code" ]] && [[ "$code" =~ ^[0-9]+$ ]]; then
			printf '%s\n' "$code"
			return 0
		fi
	fi
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
