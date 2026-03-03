#!/usr/bin/env bash
# lib/cmd/idea.sh - orchd idea command
# Queue ideas for continuous autopilot operation.
# Ideas are stored in .orchd/queue.md and automatically planned+executed
# when autopilot finishes its current task set.

cmd_idea() {
	local subcmd="${1:-}"

	case "$subcmd" in
	-h | --help)
		cat <<'EOF'
usage:
  orchd idea "your idea here"    Add an idea to the queue
  orchd idea list                List all queued ideas
  orchd idea count               Show number of pending ideas
  orchd idea clear               Remove all pending ideas (requires --force)

Ideas are picked up by `orchd autopilot` when all current tasks complete.
The system plans the idea using AI, creates tasks, and continues autonomously.
EOF
		return 0
		;;
	list | ls)
		require_project
		queue_list
		;;
	count)
		require_project
		local c
		c=$(queue_count)
		printf '%d pending idea(s)\n' "$c"
		;;
	clear)
		shift || true
		_idea_clear "$@"
		;;
	"")
		die "usage: orchd idea \"your idea\" | orchd idea list | orchd idea --help"
		;;
	*)
		# Everything else is treated as an idea to queue
		require_project
		local idea="$*"
		queue_push "$idea"
		local count
		count=$(queue_count)
		printf 'idea queued: %s\n' "$idea"
		printf 'pending ideas: %d\n' "$count"
		printf '\nideas are picked up by: orchd autopilot\n'
		;;
	esac
}

_idea_clear() {
	local force=false
	if [[ "${1:-}" == "--force" ]]; then
		force=true
	fi

	require_project

	local qf
	qf=$(queue_file)
	if [[ ! -f "$qf" ]]; then
		printf 'no idea queue found\n'
		return 0
	fi

	local count
	count=$(queue_count)
	if ((count == 0)); then
		printf 'no pending ideas to clear\n'
		return 0
	fi

	if ! $force; then
		die "this will remove $count pending idea(s). Use: orchd idea clear --force"
	fi

	# Mark all pending as cancelled
	local tmp
	tmp=$(mktemp)
	awk '
		/^- \[ \]/ {
			sub(/^- \[ \]/, "- [-]")
		}
		{ print }
	' "$qf" >"$tmp"
	mv "$tmp" "$qf"

	printf 'cleared %d pending idea(s)\n' "$count"
	log_event "INFO" "idea queue cleared: $count ideas"
}
