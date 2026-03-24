#!/usr/bin/env bash
# lib/cmd/await.sh - orchd await command
# Waits for task state changes or agent exits.

cmd_await() {
	local poll_interval=""
	local timeout=""
	local json=false
	local target="--all"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		-h | --help)
			cat <<'EOF'
usage:
  orchd await [--all] [--poll <seconds>] [--timeout <seconds>] [--json]
  orchd await <task-id> [--poll <seconds>] [--timeout <seconds>] [--json]

notes:
  - await blocks on live running agents only (status=running and agent_alive=true)
  - returns when a live agent exits or when no live running tasks remain
  - use this instead of `sleep` in long-running orchestrations
EOF
			return 0
			;;
		--poll)
			poll_interval="${2:-}"
			[[ -n "$poll_interval" ]] || die "usage: orchd await --poll <seconds>"
			shift 2
			;;
		--timeout)
			timeout="${2:-}"
			[[ -n "$timeout" ]] || die "usage: orchd await --timeout <seconds>"
			shift 2
			;;
		--json)
			json=true
			shift
			;;
		--all)
			target="--all"
			shift
			;;
		*)
			if [[ "$target" != "--all" ]]; then
				die "unknown argument: $1"
			fi
			target="$1"
			shift
			;;
		esac
	done

	require_project

	if [[ -z "$poll_interval" ]]; then
		poll_interval=$(config_get "await_poll" "5")
	fi
	if ! [[ "$poll_interval" =~ ^[0-9]+$ ]]; then
		die "poll interval must be integer seconds: $poll_interval"
	fi
	if [[ -z "$timeout" ]]; then
		timeout=$(config_get "await_timeout" "0")
	fi
	if ! [[ "$timeout" =~ ^[0-9]+$ ]]; then
		die "timeout must be integer seconds: $timeout"
	fi

	local task_count=0
	local tid
	while IFS= read -r tid; do
		[[ -z "$tid" ]] && continue
		task_count=$((task_count + 1))
		if [[ "$target" != "--all" ]] && [[ "$tid" == "$target" ]]; then
			break
		fi
	done <<<"$(task_list_ids)"
	if ((task_count == 0)); then
		die "no tasks found"
	fi
	if [[ "$target" != "--all" ]] && ! task_exists "$target"; then
		die "task not found: $target"
	fi

	local start_epoch
	start_epoch=$(date +%s)

	while true; do
		local total=0 pending=0 running=0 done_count=0 merged=0 failed=0 conflict=0 needs_input=0
		local exited_task=""
		local status

		if [[ "$target" == "--all" ]]; then
			while IFS= read -r tid; do
				[[ -z "$tid" ]] && continue
				total=$((total + 1))
				task_runtime_refresh "$tid"
				status="$TASK_RUNTIME_STATUS"
				case "$status" in
				pending) pending=$((pending + 1)) ;;
				running)
					if [[ "$TASK_RUNTIME_AGENT_ALIVE" == "true" ]]; then
						running=$((running + 1))
					elif [[ -z "$exited_task" ]]; then
						exited_task="$tid"
					fi
					;;
				done) done_count=$((done_count + 1)) ;;
				merged) merged=$((merged + 1)) ;;
				split) merged=$((merged + 1)) ;;
				failed) failed=$((failed + 1)) ;;
				conflict) conflict=$((conflict + 1)) ;;
				needs_input) needs_input=$((needs_input + 1)) ;;
				esac
			done <<<"$(task_list_ids)"

			if ((running == 0)); then
				if [[ -n "$exited_task" ]]; then
					_await_emit "$json" "agent_exited" "$exited_task" \
						"$total" "$pending" "$running" "$done_count" "$merged" "$failed" "$conflict" "$needs_input"
					return 0
				fi
				if ((done_count + failed + conflict + needs_input > 0)); then
					_await_emit "$json" "action_required" "" \
						"$total" "$pending" "$running" "$done_count" "$merged" "$failed" "$conflict" "$needs_input"
				else
					_await_emit "$json" "no_running_tasks" "" \
						"$total" "$pending" "$running" "$done_count" "$merged" "$failed" "$conflict" "$needs_input"
				fi
				return 0
			fi
		else
			task_runtime_refresh "$target"
			status="$TASK_RUNTIME_STATUS"
			case "$status" in
			pending | done | merged | split | failed | conflict | needs_input)
				_await_emit "$json" "status_${status}" "$target" \
					"1" "0" "0" "$([[ "$status" == "done" ]] && echo 1 || echo 0)" \
					"$([[ "$status" == "merged" || "$status" == "split" ]] && echo 1 || echo 0)" \
					"$([[ "$status" == "failed" ]] && echo 1 || echo 0)" \
					"$([[ "$status" == "conflict" ]] && echo 1 || echo 0)" \
					"$([[ "$status" == "needs_input" ]] && echo 1 || echo 0)"
				return 0
				;;
			running)
				if [[ "$TASK_RUNTIME_AGENT_ALIVE" != "true" ]]; then
					_await_emit "$json" "agent_exited" "$target" \
						"1" "0" "0" "0" "0" "0" "0" "0"
					return 0
				fi
				;;
			*)
				die "unknown task status: $status"
				;;
			esac
		fi

		if ((timeout > 0)); then
			local now_epoch
			now_epoch=$(date +%s)
			if ((now_epoch - start_epoch >= timeout)); then
				_await_emit "$json" "timeout" "" \
					"$total" "$pending" "$running" "$done_count" "$merged" "$failed" "$conflict" "$needs_input"
				return 1
			fi
		fi

		sleep "$poll_interval"
	done
}

_await_emit() {
	local json=$1
	local event=$2
	local task_id=$3
	local total=$4 pending=$5 running=$6 done_count=$7 merged=$8 failed=$9 conflict=${10} needs_input=${11}

	if [[ "$json" == "true" ]]; then
		printf '{"event":"%s","task_id":"%s","counts":{"total":%s,"pending":%s,"running":%s,"done":%s,"merged":%s,"failed":%s,"conflict":%s,"needs_input":%s}}\n' \
			"$event" "$task_id" "$total" "$pending" "$running" "$done_count" "$merged" "$failed" "$conflict" "$needs_input"
		return 0
	fi

	printf 'await: %s' "$event"
	if [[ -n "$task_id" ]]; then
		printf ' (%s)' "$task_id"
	fi
	printf '\n'
}
