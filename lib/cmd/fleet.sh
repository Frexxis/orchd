#!/usr/bin/env bash
# lib/cmd/fleet.sh - orchd fleet command
# Manage multiple projects from a single fleet configuration.
# Config: ~/.orchd/fleet.toml
#
# [projects.myapi]
# path = "/home/user/projects/my-api"
#
# [projects.frontend]
# path = "/home/user/projects/frontend"

cmd_fleet() {
	local subcmd="${1:-}"
	shift || true

	case "$subcmd" in
	-h | --help)
		cat <<'EOF'
usage:
  orchd fleet list                   List configured fleet projects
  orchd fleet autopilot              Start autopilot daemon for all projects
  orchd fleet status                 Show autopilot status for all projects
  orchd fleet stop                   Stop all fleet autopilot daemons
  orchd fleet brief                  Summary of what happened (last 24h)

config: ~/.orchd/fleet.toml

  [projects.myapi]
  path = "/home/user/projects/my-api"

  [projects.frontend]
  path = "/home/user/projects/frontend"
EOF
		return 0
		;;
	list | ls)
		_fleet_list
		;;
	autopilot)
		_fleet_autopilot "$@"
		;;
	status)
		_fleet_status
		;;
	stop)
		_fleet_stop
		;;
	brief)
		_fleet_brief "$@"
		;;
	"")
		_fleet_list
		;;
	*)
		die "unknown fleet subcommand: $subcmd (try: orchd fleet --help)"
		;;
	esac
}

_fleet_require_config() {
	local cfg
	cfg=$(fleet_config_file)
	if [[ ! -f "$cfg" ]]; then
		die "fleet config not found: $cfg
Create it with:

  mkdir -p ~/.orchd
  cat > ~/.orchd/fleet.toml <<'TOML'
[projects.myproject]
path = \"/path/to/project\"
TOML"
	fi
}

_fleet_trim_edges() {
	# Trim only leading/trailing whitespace; preserve internal spaces.
	printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

_fleet_list() {
	_fleet_require_config

	local projects
	projects=$(fleet_list_projects) || {
		printf 'no projects configured in %s\n' "$(fleet_config_file)"
		return 0
	}

	if [[ -z "$projects" ]]; then
		printf 'no projects configured in %s\n' "$(fleet_config_file)"
		return 0
	fi

	printf '%-20s %-40s %s\n' "ID" "PATH" "STATUS"
	printf '%-20s %-40s %s\n' "---" "---" "---"

	local proj_id proj_path
	while IFS=$'\t' read -r proj_id proj_path; do
		proj_id=$(_fleet_trim_edges "$proj_id")
		proj_path=$(_fleet_trim_edges "$proj_path")
		[[ -z "$proj_id" ]] && continue

		local status="--"
		if [[ ! -d "$proj_path" ]]; then
			status="missing"
		elif [[ ! -f "$proj_path/.orchd.toml" ]]; then
			status="not initialized"
		elif [[ -f "$proj_path/.orchd/autopilot.pid" ]]; then
			local pid
			pid=$(cat "$proj_path/.orchd/autopilot.pid" 2>/dev/null || true)
			if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
				status="running (pid $pid)"
			else
				status="idle (stale pid)"
			fi
		else
			status="idle"
		fi

		printf '%-20s %-40s %s\n' "$proj_id" "$proj_path" "$status"
	done <<<"$projects"
}

_fleet_autopilot() {
	_fleet_require_config

	local projects
	projects=$(fleet_list_projects) || die "no projects configured"
	[[ -n "$projects" ]] || die "no projects configured"

	local poll_interval="${1:-}"

	local started=0 skipped=0 errors=0
	local proj_id proj_path
	while IFS=$'\t' read -r proj_id proj_path; do
		proj_id=$(_fleet_trim_edges "$proj_id")
		proj_path=$(_fleet_trim_edges "$proj_path")
		[[ -z "$proj_id" ]] && continue

		if [[ ! -d "$proj_path" ]]; then
			printf '  [SKIP] %s: directory not found: %s\n' "$proj_id" "$proj_path"
			skipped=$((skipped + 1))
			continue
		fi

		if [[ ! -f "$proj_path/.orchd.toml" ]]; then
			printf '  [SKIP] %s: not an orchd project (no .orchd.toml)\n' "$proj_id"
			skipped=$((skipped + 1))
			continue
		fi

		# Check if already running
		if [[ -f "$proj_path/.orchd/autopilot.pid" ]]; then
			local pid
			pid=$(cat "$proj_path/.orchd/autopilot.pid" 2>/dev/null || true)
			if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
				printf '  [SKIP] %s: autopilot already running (pid %s)\n' "$proj_id" "$pid"
				skipped=$((skipped + 1))
				continue
			fi
		fi

		# Start autopilot daemon for this project
		local log_file="$proj_path/.orchd/autopilot.log"
		local pid_file="$proj_path/.orchd/autopilot.pid"
		mkdir -p "$proj_path/.orchd"

		local daemon_args="autopilot"
		if [[ -n "$poll_interval" ]]; then
			daemon_args="autopilot $poll_interval"
		fi

		# shellcheck disable=SC2086
		(
			cd "$proj_path" && nohup "$ORCHD_BIN" $daemon_args >"$log_file" 2>&1 &
			printf '%s\n' "$!" >"$pid_file"
		)

		if [[ -f "$pid_file" ]]; then
			local new_pid
			new_pid=$(cat "$pid_file" 2>/dev/null || true)
			if [[ -n "$new_pid" ]] && kill -0 "$new_pid" >/dev/null 2>&1; then
				printf '  [START] %s: autopilot started (pid %s)\n' "$proj_id" "$new_pid"
				started=$((started + 1))
			else
				printf '  [ERROR] %s: autopilot exited immediately\n' "$proj_id"
				rm -f "$pid_file"
				errors=$((errors + 1))
			fi
		else
			printf '  [ERROR] %s: failed to start autopilot\n' "$proj_id"
			errors=$((errors + 1))
		fi
	done <<<"$projects"

	printf '\nfleet autopilot: %d started, %d skipped, %d errors\n' "$started" "$skipped" "$errors"
}

_fleet_status() {
	_fleet_require_config

	local projects
	projects=$(fleet_list_projects) || die "no projects configured"
	[[ -n "$projects" ]] || die "no projects configured"

	printf '%-20s %-12s %-8s %s\n' "PROJECT" "AUTOPILOT" "TASKS" "DETAIL"
	printf '%-20s %-12s %-8s %s\n' "---" "---" "---" "---"

	local proj_id proj_path
	while IFS=$'\t' read -r proj_id proj_path; do
		proj_id=$(_fleet_trim_edges "$proj_id")
		proj_path=$(_fleet_trim_edges "$proj_path")
		[[ -z "$proj_id" ]] && continue

		local ap_status="--" task_info="--" detail=""

		if [[ ! -d "$proj_path" ]]; then
			ap_status="missing"
			printf '%-20s %-12s %-8s %s\n' "$proj_id" "$ap_status" "--" "directory not found"
			continue
		fi

		# Autopilot status
		if [[ -f "$proj_path/.orchd/autopilot.pid" ]]; then
			local pid
			pid=$(cat "$proj_path/.orchd/autopilot.pid" 2>/dev/null || true)
			if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
				ap_status="running"
			else
				ap_status="idle"
			fi
		else
			ap_status="idle"
		fi

		# Task counts (read state directly, no require_project needed)
		if [[ -d "$proj_path/.orchd/tasks" ]]; then
			local total=0 merged=0 running=0 failed=0
			local td
			for td in "$proj_path/.orchd/tasks"/*/; do
				[[ -d "$td" ]] || continue
				total=$((total + 1))
				if [[ -f "$td/status" ]]; then
					local st
					st=$(cat "$td/status" 2>/dev/null || true)
					case "$st" in
					merged) merged=$((merged + 1)) ;;
					running) running=$((running + 1)) ;;
					failed) failed=$((failed + 1)) ;;
					esac
				fi
			done
			task_info="${merged}/${total}"
			if ((running > 0)); then
				detail="running:$running"
			fi
			if ((failed > 0)); then
				detail="${detail:+$detail }failed:$failed"
			fi
		fi

		printf '%-20s %-12s %-8s %s\n' "$proj_id" "$ap_status" "$task_info" "$detail"
	done <<<"$projects"
}

_fleet_stop() {
	_fleet_require_config

	local projects
	projects=$(fleet_list_projects) || die "no projects configured"
	[[ -n "$projects" ]] || die "no projects configured"

	local stopped=0 not_running=0
	local proj_id proj_path
	while IFS=$'\t' read -r proj_id proj_path; do
		proj_id=$(_fleet_trim_edges "$proj_id")
		proj_path=$(_fleet_trim_edges "$proj_path")
		[[ -z "$proj_id" ]] && continue

		local pid_file="$proj_path/.orchd/autopilot.pid"
		if [[ ! -f "$pid_file" ]]; then
			not_running=$((not_running + 1))
			continue
		fi

		local pid
		pid=$(cat "$pid_file" 2>/dev/null || true)
		if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
			kill "$pid" >/dev/null 2>&1 || true
			printf '  [STOP] %s: stopped (pid %s)\n' "$proj_id" "$pid"
			stopped=$((stopped + 1))
		else
			not_running=$((not_running + 1))
		fi
		rm -f "$pid_file"
	done <<<"$projects"

	printf '\nfleet: %d stopped, %d were not running\n' "$stopped" "$not_running"
}

_fleet_brief() {
	_fleet_require_config

	local hours="${1:-24}"
	if ! [[ "$hours" =~ ^[0-9]+$ ]]; then
		hours=24
	fi

	local projects
	projects=$(fleet_list_projects) || die "no projects configured"
	[[ -n "$projects" ]] || die "no projects configured"

	local cutoff_iso
	cutoff_iso=$(date -u -d "$hours hours ago" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v-"${hours}"H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "")

	printf 'Fleet Brief (last %dh)\n\n' "$hours"
	printf '%-20s %-8s %-8s %-8s %-12s %s\n' "PROJECT" "MERGED" "FAILED" "NEEDS" "STATUS" "QUEUE"
	printf '%-20s %-8s %-8s %-8s %-12s %s\n' "---" "---" "---" "---" "---" "---"

	local proj_id proj_path
	while IFS=$'\t' read -r proj_id proj_path; do
		proj_id=$(_fleet_trim_edges "$proj_id")
		proj_path=$(_fleet_trim_edges "$proj_path")
		[[ -z "$proj_id" ]] && continue

		local merged=0 failed=0 needs=0 ap_status="idle" queue_count=0

		if [[ ! -d "$proj_path" ]]; then
			printf '%-20s %-8s %-8s %-8s %-12s %s\n' "$proj_id" "--" "--" "--" "missing" "--"
			continue
		fi

		# Parse orchd.log for recent events
		local log_file="$proj_path/.orchd/orchd.log"
		if [[ -f "$log_file" ]]; then
			local counts
			counts=$(awk -v cutoff="$cutoff_iso" '
				{
					ts = ""
					if (match($0, /^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\]/)) {
						ts = substr($0, 2, RLENGTH - 2)
					}
					if (cutoff != "" && (ts == "" || ts < cutoff)) {
						next
					}
					if ($0 ~ /task merged:/) {
						merged++
					}
					if ($0 ~ /quality gate failed:/ || $0 ~ /autopilot:.*needs_input/) {
						failed++
					}
					if ($0 ~ /needs.input:/) {
						needs++
					}
				}
				END { print merged+0 "\t" failed+0 "\t" needs+0 }
			' "$log_file")
			IFS=$'\t' read -r merged failed needs <<<"$counts"
		fi

		# Autopilot status
		if [[ -f "$proj_path/.orchd/autopilot.pid" ]]; then
			local pid
			pid=$(cat "$proj_path/.orchd/autopilot.pid" 2>/dev/null || true)
			if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
				ap_status="running"
			fi
		fi

		# Queue count
		local qf="$proj_path/.orchd/queue.md"
		if [[ -f "$qf" ]]; then
			queue_count=$(awk '/^- \[ \]/ { c++ } END { print c+0 }' "$qf")
		fi

		printf '%-20s %-8d %-8d %-8d %-12s %d\n' "$proj_id" "$merged" "$failed" "$needs" "$ap_status" "$queue_count"
	done <<<"$projects"

	printf '\nconfig: %s\n' "$(fleet_config_file)"
}
