#!/usr/bin/env bash
# lib/cmd/board.sh - orchd board command
# Live status dashboard for all tasks and agents

cmd_board() {
	local mode="${1:-}"

	require_project

	if [[ "$mode" == "--watch" ]] || [[ "$mode" == "-w" ]]; then
		_board_watch
	else
		_board_print
	fi
}

_board_print() {
	local runner
	runner=$(detect_runner)

	local total=0 pending=0 running=0 done_count=0 merged=0 failed=0

	printf '\033[1m'
	printf '┌──────────────────────────────────────────────────────────────────────────────┐\n'
	printf '│                           orchd - agent board                               │\n'
	printf '├──────────────────────┬────────────────────────────┬────────┬─────────────────┤\n'
	printf '│ %-20s │ %-26s │ %-6s │ %-15s │\n' "TASK" "TITLE" "STATUS" "AGENT"
	printf '├──────────────────────┼────────────────────────────┼────────┼─────────────────┤\n'
	printf '\033[0m'

	local task_id
	while IFS= read -r task_id; do
		[[ -z "$task_id" ]] && continue
		total=$((total + 1))

		local title status
		title=$(task_get "$task_id" "title" "-")
		status=$(task_get "$task_id" "status" "pending")

		# Truncate title
		if ((${#title} > 26)); then
			title="${title:0:23}..."
		fi

		# Status with color
		local status_display
		case "$status" in
		pending)
			status_display="\033[90m·pend\033[0m "
			pending=$((pending + 1))
			;;
		running)
			if runner_is_alive "$task_id"; then
				status_display="\033[32m●run \033[0m "
			else
				status_display="\033[33m○stale\033[0m"
			fi
			running=$((running + 1))
			;;
		done)
			status_display="\033[34m✓done\033[0m "
			done_count=$((done_count + 1))
			;;
		merged)
			status_display="\033[32m✓mrgd\033[0m "
			merged=$((merged + 1))
			;;
		failed)
			status_display="\033[31m✗fail\033[0m "
			failed=$((failed + 1))
			;;
		*)
			status_display="$status"
			;;
		esac

		# Agent info
		local agent_info="-"
		local session_name
		session_name=$(task_get "$task_id" "session" "")
		if [[ -n "$session_name" ]]; then
			if tmux has-session -t "$session_name" 2>/dev/null; then
				agent_info="\033[32malive\033[0m"
			else
				agent_info="\033[90mexited\033[0m"
			fi
		fi

		printf "│ %-20s │ %-26s │ ${status_display} │ %-15b │\n" \
			"$task_id" "$title" "$agent_info"
	done <<<"$(task_list_ids)"

	if ((total == 0)); then
		printf '│ %-73s │\n' "  (no tasks — run: orchd plan \"<description>\")"
	fi

	printf '\033[1m'
	printf '├──────────────────────┴────────────────────────────┴────────┴─────────────────┤\n'

	local progress_pct=0
	if ((total > 0)); then
		progress_pct=$(((merged * 100) / total))
	fi

	# Progress bar
	local bar_width=40
	local filled=$(((progress_pct * bar_width) / 100))
	local empty=$((bar_width - filled))
	local bar=""
	local i
	for ((i = 0; i < filled; i++)); do bar+="█"; done
	for ((i = 0; i < empty; i++)); do bar+="░"; done

	printf '│ %s %3d%%                                            │\n' "$bar" "$progress_pct"
	printf '│ total: %d │ pending: %d │ running: %d │ done: %d │ merged: %d │ failed: %d   │\n' \
		"$total" "$pending" "$running" "$done_count" "$merged" "$failed"
	printf '│ runner: %-12s                                                        │\n' "$runner"
	printf '└──────────────────────────────────────────────────────────────────────────────┘\n'
	printf '\033[0m'
}

_board_watch() {
	local interval
	interval=$(config_get "monitor_interval" "5")

	while true; do
		clear
		_board_print
		printf '\n\033[90mrefreshing every %ss — press Ctrl+C to exit\033[0m\n' "$interval"
		sleep "$interval"
	done
}
