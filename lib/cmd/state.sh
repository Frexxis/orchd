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

_deps_csv_all_merged() {
	local deps=${1:-}
	[[ -n "$deps" ]] || return 0

	local dep dep_status
	while IFS=',' read -ra dep_arr; do
		for dep in "${dep_arr[@]}"; do
			dep=$(printf '%s' "$dep" | tr -d '[:space:]')
			[[ -z "$dep" ]] && continue
			dep_status=$(task_field_cached "$dep" "status" "pending")
			[[ "$dep_status" == "merged" ]] || return 1
		done
	done <<<"$deps"
	return 0
}

_deps_all_merged() {
	local task_id=$1
	local deps=${2:-}
	if [[ -z "$deps" ]]; then
		deps=$(task_field_cached "$task_id" "deps" "")
	fi
	_deps_csv_all_merged "$deps"
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
	cache_tick_begin
	local base_branch worktree_dir max_parallel runner
	base_branch=$(config_get_cached "base_branch" "main")
	worktree_dir=$(config_get_cached "worktree_dir" ".worktrees")
	max_parallel=$(config_get_cached "max_parallel" "3")
	runner=$(detect_runner)

	local total=0 pending=0 running=0 done_count=0 merged=0 failed=0 conflict=0 needs_input=0
	local checkable=0 mergeable=0 spawnable=0

	local task_id status
	while IFS= read -r task_id; do
		[[ -z "$task_id" ]] && continue
		total=$((total + 1))
		status=$(task_field_cached "$task_id" "status" "pending")
		case "$status" in
		pending)
			pending=$((pending + 1))
			local deps
			deps=$(task_field_cached "$task_id" "deps" "")
			if _deps_csv_all_merged "$deps"; then
				spawnable=$((spawnable + 1))
			fi
			;;
		running)
			running=$((running + 1))
			if ! runner_is_alive "$task_id"; then
				checkable=$((checkable + 1))
			fi
			;;
		done)
			done_count=$((done_count + 1))
			local deps
			deps=$(task_field_cached "$task_id" "deps" "")
			if _deps_csv_all_merged "$deps"; then
				mergeable=$((mergeable + 1))
			fi
			;;
		merged) merged=$((merged + 1)) ;;
		failed) failed=$((failed + 1)) ;;
		conflict) conflict=$((conflict + 1)) ;;
		needs_input) needs_input=$((needs_input + 1)) ;;
		esac
	done <<<"$(task_list_ids_cached)"

	printf 'project:      %s\n' "$PROJECT_ROOT"
	printf 'base_branch:  %s\n' "$base_branch"
	printf 'worktrees:    %s/%s\n' "$PROJECT_ROOT" "$worktree_dir"
	printf 'worker_runner:%s\n' "$runner"
	printf 'tasks:        total=%d pending=%d running=%d done=%d merged=%d failed=%d conflict=%d needs_input=%d\n' \
		"$total" "$pending" "$running" "$done_count" "$merged" "$failed" "$conflict" "$needs_input"
	printf 'ready:        spawn=%d check=%d merge=%d (max_parallel=%s)\n' "$spawnable" "$checkable" "$mergeable" "$max_parallel"

	if ((total == 0)); then
		printf '\nno tasks found (run: orchd plan ...)\n'
		cache_tick_end
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

	cache_tick_end
}

_state_json() {
	cache_tick_begin
	local base_branch worktree_dir max_parallel runner
	base_branch=$(config_get_cached "base_branch" "main")
	worktree_dir=$(config_get_cached "worktree_dir" ".worktrees")
	max_parallel=$(config_get_cached "max_parallel" "3")
	runner=$(detect_runner)

	local total=0 pending=0 running=0 done_count=0 merged=0 failed=0 conflict=0 needs_input=0
	local checkable=0 mergeable=0 spawnable=0

	local ids=()
	local task_id
	while IFS= read -r task_id; do
		[[ -z "$task_id" ]] && continue
		ids+=("$task_id")
	done <<<"$(task_list_ids_cached)"

	local status
	local task_items=()
	for task_id in "${ids[@]}"; do
		local title role deps branch worktree session attempts checked_at merged_at last_failure_reason task_runner
		title=$(task_field_cached "$task_id" "title" "")
		role=$(task_field_cached "$task_id" "role" "")
		deps=$(task_field_cached "$task_id" "deps" "")
		branch=$(task_field_cached "$task_id" "branch" "")
		worktree=$(task_field_cached "$task_id" "worktree" "")
		session=$(task_field_cached "$task_id" "session" "")
		attempts=$(task_field_cached "$task_id" "attempts" "0")
		checked_at=$(task_field_cached "$task_id" "checked_at" "")
		merged_at=$(task_field_cached "$task_id" "merged_at" "")
		last_failure_reason=$(task_field_cached "$task_id" "last_failure_reason" "")
		task_runner=$(task_field_cached "$task_id" "runner" "")

		local agent_alive=false
		local log_file
		log_file=$(_task_log_file "$task_id")

		total=$((total + 1))
		status=$(task_field_cached "$task_id" "status" "pending")
		case "$status" in
		pending)
			pending=$((pending + 1))
			if _deps_csv_all_merged "$deps"; then spawnable=$((spawnable + 1)); fi
			;;
		running)
			running=$((running + 1))
			if runner_is_alive "$task_id"; then
				agent_alive=true
			else
				checkable=$((checkable + 1))
			fi
			;;
		done)
			done_count=$((done_count + 1))
			if _deps_csv_all_merged "$deps"; then mergeable=$((mergeable + 1)); fi
			;;
		merged) merged=$((merged + 1)) ;;
		failed) failed=$((failed + 1)) ;;
		conflict) conflict=$((conflict + 1)) ;;
		needs_input) needs_input=$((needs_input + 1)) ;;
		esac

		task_items+=("{\"id\":\"$(_json_escape "$task_id")\",\"title\":\"$(_json_escape "$title")\",\"role\":\"$(_json_escape "$role")\",\"status\":\"$(_json_escape "$status")\",\"deps\":\"$(_json_escape "$deps")\",\"branch\":\"$(_json_escape "$branch")\",\"worktree\":\"$(_json_escape "$worktree")\",\"runner\":\"$(_json_escape "$task_runner")\",\"session\":\"$(_json_escape "$session")\",\"agent_alive\":$agent_alive,\"attempts\":$(_json_escape "$attempts"),\"checked_at\":\"$(_json_escape "$checked_at")\",\"merged_at\":\"$(_json_escape "$merged_at")\",\"last_failure_reason\":\"$(_json_escape "$last_failure_reason")\",\"log_file\":\"$(_json_escape "$log_file")\"}")
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

	local kpi_json
	kpi_json=$(metrics_kpi_json)
	printf '"kpi":%s,' "$kpi_json"

	printf '"tasks":['
	local first=true
	local item
	for item in "${task_items[@]}"; do
		if $first; then
			first=false
		else
			printf ','
		fi
		printf '%s' "$item"
	done
	printf ']'
	printf '}\n'

	cache_tick_end
}
