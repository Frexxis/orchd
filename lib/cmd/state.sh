#!/usr/bin/env bash
# lib/cmd/state.sh - orchd state command
# Prints a machine-friendly snapshot of orchd task state.

_json_escape() {
	local s=${1-}
	s=${s//\\/\\\\}
	s=${s//"/\\"/}
	s=${s//$'\n'/\\n}
	s=${s//$'\r'/\\r}
	s=${s//$'\t'/\\t}
	printf '%s' "$s"
}

_task_log_file() {
	local task_id=$1
	local log_file=""
	if [[ -f "$LOGS_DIR/${task_id}.log" ]]; then
		log_file="$LOGS_DIR/${task_id}.log"
	elif [[ -f "$LOGS_DIR/${task_id}.jsonl" ]]; then
		log_file="$LOGS_DIR/${task_id}.jsonl"
	fi
	printf '%s\n' "$log_file"
}

_deps_all_merged() {
	local task_id=$1
	local deps
	deps=$(task_get "$task_id" "deps" "")
	[[ -n "$deps" ]] || return 0

	local dep dep_status
	while IFS=',' read -ra dep_arr; do
		for dep in "${dep_arr[@]}"; do
			dep=$(printf '%s' "$dep" | tr -d '[:space:]')
			[[ -z "$dep" ]] && continue
			dep_status=$(task_status "$dep")
			[[ "$dep_status" == "merged" ]] || return 1
		done
	done <<<"$deps"
	return 0
}

cmd_state() {
	local mode="${1:-}"

	require_project

	case "$mode" in
	--json | -j)
		_state_json
		;;
	"" | --text | -t)
		_state_text
		;;
	-h | --help)
		printf '%s\n' "usage: orchd state [--json]"
		;;
	*)
		die "usage: orchd state [--json]"
		;;
	esac
}

_state_text() {
	local base_branch worktree_dir max_parallel runner
	base_branch=$(config_get "base_branch" "main")
	worktree_dir=$(config_get "worktree_dir" ".worktrees")
	max_parallel=$(config_get "max_parallel" "3")
	runner=$(detect_runner)

	local total=0 pending=0 running=0 done_count=0 merged=0 failed=0 conflict=0 needs_input=0
	local checkable=0 mergeable=0 spawnable=0

	local task_id status
	while IFS= read -r task_id; do
		[[ -z "$task_id" ]] && continue
		total=$((total + 1))
		task_runtime_refresh "$task_id"
		status="$TASK_RUNTIME_STATUS"
		case "$status" in
		pending)
			pending=$((pending + 1))
			if task_is_ready "$task_id"; then
				spawnable=$((spawnable + 1))
			fi
			;;
		running)
			if [[ "$TASK_RUNTIME_AGENT_ALIVE" == "true" ]]; then
				running=$((running + 1))
			fi
			if [[ "$TASK_RUNTIME_AGENT_ALIVE" != "true" ]]; then
				checkable=$((checkable + 1))
			fi
			;;
		done)
			done_count=$((done_count + 1))
			if _deps_all_merged "$task_id"; then
				mergeable=$((mergeable + 1))
			fi
			;;
		merged) merged=$((merged + 1)) ;;
		failed) failed=$((failed + 1)) ;;
		conflict) conflict=$((conflict + 1)) ;;
		needs_input) needs_input=$((needs_input + 1)) ;;
		esac
	done <<<"$(task_list_ids)"

	printf 'project:      %s\n' "$PROJECT_ROOT"
	printf 'base_branch:  %s\n' "$base_branch"
	printf 'worktrees:    %s/%s\n' "$PROJECT_ROOT" "$worktree_dir"
	printf 'worker_runner:%s\n' "$runner"
	printf 'tasks:        total=%d pending=%d running=%d done=%d merged=%d failed=%d conflict=%d needs_input=%d\n' \
		"$total" "$pending" "$running" "$done_count" "$merged" "$failed" "$conflict" "$needs_input"
	printf 'ready:        spawn=%d check=%d merge=%d (max_parallel=%s)\n' "$spawnable" "$checkable" "$mergeable" "$max_parallel"

	if ((total == 0)); then
		printf '\nno tasks found (run: orchd plan ...)\n'
		return 0
	fi

	printf '\nnext:\n'
	if ((checkable > 0)); then
		printf '  orchd check --all\n'
	fi
	if ((mergeable > 0)); then
		printf '  orchd merge --all\n'
	fi
	if ((spawnable > 0)) && ((running < max_parallel)); then
		printf '  orchd spawn --all\n'
	fi
}

_state_json() {
	local base_branch worktree_dir max_parallel runner
	base_branch=$(config_get "base_branch" "main")
	worktree_dir=$(config_get "worktree_dir" ".worktrees")
	max_parallel=$(config_get "max_parallel" "3")
	runner=$(detect_runner)

	local total=0 pending=0 running=0 done_count=0 merged=0 failed=0 conflict=0 needs_input=0
	local checkable=0 mergeable=0 spawnable=0

	local ids=()
	local task_id
	while IFS= read -r task_id; do
		[[ -z "$task_id" ]] && continue
		ids+=("$task_id")
	done <<<"$(task_list_ids)"

	local status
	for task_id in "${ids[@]}"; do
		total=$((total + 1))
		task_runtime_refresh "$task_id"
		status="$TASK_RUNTIME_STATUS"
		case "$status" in
		pending)
			pending=$((pending + 1))
			if task_is_ready "$task_id"; then spawnable=$((spawnable + 1)); fi
			;;
		running)
			if [[ "$TASK_RUNTIME_AGENT_ALIVE" == "true" ]]; then
				running=$((running + 1))
			fi
			if [[ "$TASK_RUNTIME_AGENT_ALIVE" != "true" ]]; then checkable=$((checkable + 1)); fi
			;;
		done)
			done_count=$((done_count + 1))
			if _deps_all_merged "$task_id"; then mergeable=$((mergeable + 1)); fi
			;;
		merged) merged=$((merged + 1)) ;;
		failed) failed=$((failed + 1)) ;;
		conflict) conflict=$((conflict + 1)) ;;
		needs_input) needs_input=$((needs_input + 1)) ;;
		esac
	done

	printf '{'
	printf '"project_root":"%s",' "$(_json_escape "$PROJECT_ROOT")"
	printf '"base_branch":"%s",' "$(_json_escape "$base_branch")"
	printf '"worktree_dir":"%s",' "$(_json_escape "$worktree_dir")"
	printf '"worker_runner":"%s",' "$(_json_escape "$runner")"
	printf '"max_parallel":%s,' "$(_json_escape "$max_parallel")"
	printf '"counts":{'
	printf '"total":%d,' "$total"
	printf '"pending":%d,' "$pending"
	printf '"running":%d,' "$running"
	printf '"done":%d,' "$done_count"
	printf '"merged":%d,' "$merged"
	printf '"failed":%d,' "$failed"
	printf '"conflict":%d,' "$conflict"
	printf '"needs_input":%d' "$needs_input"
	printf '},'
	printf '"ready":{'
	printf '"spawn":%d,' "$spawnable"
	printf '"check":%d,' "$checkable"
	printf '"merge":%d' "$mergeable"
	printf '},'

	printf '"tasks":['
	local first=true
	for task_id in "${ids[@]}"; do
		if $first; then first=false; else printf ','; fi

		local title role deps branch worktree session attempts checked_at merged_at last_failure_reason
		title=$(task_get "$task_id" "title" "")
		role=$(task_get "$task_id" "role" "")
		deps=$(task_get "$task_id" "deps" "")
		branch=$(task_get "$task_id" "branch" "")
		worktree=$(task_get "$task_id" "worktree" "")
		session=$(task_get "$task_id" "session" "")
		attempts=$(task_get "$task_id" "attempts" "0")
		checked_at=$(task_get "$task_id" "checked_at" "")
		merged_at=$(task_get "$task_id" "merged_at" "")
		last_failure_reason=$(task_get "$task_id" "last_failure_reason" "")

		task_runtime_refresh "$task_id"
		status="$TASK_RUNTIME_STATUS"
		local agent_alive
		agent_alive="$TASK_RUNTIME_AGENT_ALIVE"
		local effective_status
		effective_status="$TASK_RUNTIME_EFFECTIVE_STATUS"
		local session_state="none"
		if [[ "$TASK_RUNTIME_SESSION_PRESENT" == "true" ]]; then
			if [[ "$TASK_RUNTIME_AGENT_ALIVE" == "true" ]]; then
				session_state="alive"
			else
				session_state="stale"
			fi
		fi
		local log_file
		log_file=$(_task_log_file "$task_id")
		local needs_input_source needs_input_file needs_input_code needs_input_summary needs_input_question needs_input_blocking needs_input_options needs_input_error
		needs_input_source=$(task_get "$task_id" "needs_input_source" "")
		needs_input_file=$(task_get "$task_id" "needs_input_file" "")
		needs_input_code=$(task_get "$task_id" "needs_input_code" "")
		needs_input_summary=$(task_get "$task_id" "needs_input_summary" "")
		needs_input_question=$(task_get "$task_id" "needs_input_question" "")
		needs_input_blocking=$(task_get "$task_id" "needs_input_blocking" "")
		needs_input_options=$(task_get "$task_id" "needs_input_options" "")
		needs_input_error=$(task_get "$task_id" "needs_input_error" "")

		if [[ "$status" == "needs_input" ]] && [[ -z "$needs_input_source" ]] && [[ -n "$worktree" ]] && [[ -d "$worktree" ]]; then
			needs_input_detect "$worktree"
			if [[ "$ORCHD_NEEDS_INPUT_PRESENT" == "true" ]]; then
				needs_input_source="$ORCHD_NEEDS_INPUT_SOURCE"
				needs_input_file="$ORCHD_NEEDS_INPUT_FILE"
				needs_input_code="$ORCHD_NEEDS_INPUT_CODE"
				needs_input_summary="$ORCHD_NEEDS_INPUT_SUMMARY"
				needs_input_question="$ORCHD_NEEDS_INPUT_QUESTION"
				needs_input_blocking="$ORCHD_NEEDS_INPUT_BLOCKING"
				needs_input_options="$ORCHD_NEEDS_INPUT_OPTIONS"
				needs_input_error="$ORCHD_NEEDS_INPUT_ERROR"
			fi
		fi

		printf '{'
		printf '"id":"%s",' "$(_json_escape "$task_id")"
		printf '"title":"%s",' "$(_json_escape "$title")"
		printf '"role":"%s",' "$(_json_escape "$role")"
		printf '"status":"%s",' "$(_json_escape "$status")"
		printf '"effective_status":"%s",' "$(_json_escape "$effective_status")"
		printf '"deps":"%s",' "$(_json_escape "$deps")"
		printf '"branch":"%s",' "$(_json_escape "$branch")"
		printf '"worktree":"%s",' "$(_json_escape "$worktree")"
		printf '"runner":"%s",' "$(_json_escape "$(task_get "$task_id" "runner" "")")"
		printf '"session":"%s",' "$(_json_escape "$session")"
		printf '"session_state":"%s",' "$(_json_escape "$session_state")"
		printf '"agent_alive":%s,' "$agent_alive"
		printf '"attempts":%s,' "$(_json_escape "$attempts")"
		printf '"checked_at":"%s",' "$(_json_escape "$checked_at")"
		printf '"merged_at":"%s",' "$(_json_escape "$merged_at")"
		printf '"last_failure_reason":"%s",' "$(_json_escape "$last_failure_reason")"
		printf '"log_file":"%s",' "$(_json_escape "$log_file")"
		if [[ -n "$needs_input_source" || -n "$needs_input_file" || "$status" == "needs_input" ]]; then
			printf '"needs_input":{'
			printf '"source":"%s",' "$(_json_escape "$needs_input_source")"
			printf '"file":"%s",' "$(_json_escape "$needs_input_file")"
			printf '"code":"%s",' "$(_json_escape "$needs_input_code")"
			printf '"summary":"%s",' "$(_json_escape "$needs_input_summary")"
			printf '"question":"%s",' "$(_json_escape "$needs_input_question")"
			printf '"blocking":"%s",' "$(_json_escape "$needs_input_blocking")"
			printf '"options":"%s",' "$(_json_escape "$needs_input_options")"
			printf '"error":"%s"' "$(_json_escape "$needs_input_error")"
			printf '}'
		else
			printf '"needs_input":null'
		fi
		printf '}'
	done
	printf ']'
	printf '}\n'
}
