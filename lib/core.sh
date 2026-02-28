#!/usr/bin/env bash
# lib/core.sh - Shared utilities, config loading, state management
# Sourced by bin/orchd — do not execute directly.

# --- Project root detection ---

find_project_root() {
	local dir="${1:-$PWD}"
	while [[ "$dir" != "/" ]]; do
		if [[ -f "$dir/.orchd.toml" ]]; then
			printf '%s\n' "$dir"
			return 0
		fi
		dir=$(dirname "$dir")
	done
	return 1
}

require_project() {
	PROJECT_ROOT=$(find_project_root) || die "not an orchd project (no .orchd.toml found). Run: orchd init"
	ORCHD_DIR="$PROJECT_ROOT/.orchd"
	TASKS_DIR="$ORCHD_DIR/tasks"
	LOGS_DIR="$ORCHD_DIR/logs"
	mkdir -p "$TASKS_DIR" "$LOGS_DIR"
}

# --- Config parsing (.orchd.toml, minimal TOML subset) ---

config_get() {
	local key=$1
	local default=${2:-}
	local project_root="${PROJECT_ROOT:-}"
	local value

	if [[ -z "$project_root" ]]; then
		project_root=$(find_project_root "$PWD" 2>/dev/null || true)
	fi

	if [[ -n "$project_root" ]] && [[ -f "$project_root/.orchd.toml" ]]; then
		value=$(awk -v wanted="$key" '
			BEGIN {
				section = ""
				wanted_section = ""
				wanted_key = wanted
				dot = index(wanted, ".")
				if (dot > 0) {
					wanted_section = substr(wanted, 1, dot - 1)
					wanted_key = substr(wanted, dot + 1)
				}
				best_rank = 999
			}

			function trim(s) {
				sub(/^[[:space:]]+/, "", s)
				sub(/[[:space:]]+$/, "", s)
				return s
			}

			function rank(sec) {
				if (wanted_section != "") {
					if (sec == wanted_section) return 0
					return 999
				}
				if (sec == "orchestrator") return 1
				if (sec == "project") return 2
				if (sec == "quality") return 3
				if (sec ~ /^runners\./) return 4
				if (sec == "") return 5
				return 6
			}

			{
				line = $0
				sub(/\r$/, "", line)
				if (line ~ /^[[:space:]]*#/ || line ~ /^[[:space:]]*$/) next

				if (match(line, /^[[:space:]]*\[[^]]+\][[:space:]]*$/)) {
					sec = line
					gsub(/^[[:space:]]*\[/, "", sec)
					gsub(/\][[:space:]]*$/, "", sec)
					section = sec
					next
				}

				eq = index(line, "=")
				if (eq == 0) next

				raw_key = trim(substr(line, 1, eq - 1))
				raw_val = trim(substr(line, eq + 1))
				if (raw_key != wanted_key) next

				r = rank(section)
				if (r >= best_rank) next

				if (raw_val ~ /^"/) {
					val = raw_val
					sub(/^"/, "", val)
					sub(/"[[:space:]]*(#.*)?$/, "", val)
					gsub(/\\"/, "\"", val)
					gsub(/\\n/, "\n", val)
					gsub(/\\r/, "\r", val)
					gsub(/\\t/, "\t", val)
					gsub(/\\\\/, "\\", val)
				} else {
					val = raw_val
					sub(/[[:space:]]+#.*$/, "", val)
					val = trim(val)
				}

				best_val = val
				best_rank = r
				if (best_rank == 0) {
					print best_val
					exit
				}
			}

			END {
				if (best_rank < 999) print best_val
			}
		' "$project_root/.orchd.toml" 2>/dev/null)
	fi
	printf '%s\n' "${value:-$default}"
}

# --- Task state management ---

task_dir() {
	local task_id=$1
	printf '%s\n' "$TASKS_DIR/$task_id"
}

task_set() {
	local task_id=$1
	local key=$2
	local value=$3
	local dir
	dir=$(task_dir "$task_id")
	mkdir -p "$dir"
	printf '%s\n' "$value" >"$dir/$key"
}

task_get() {
	local task_id=$1
	local key=$2
	local default=${3:-}
	local dir
	dir=$(task_dir "$task_id")
	if [[ -f "$dir/$key" ]]; then
		cat "$dir/$key"
	else
		printf '%s\n' "$default"
	fi
}

task_exists() {
	local task_id=$1
	[[ -d "$(task_dir "$task_id")" ]]
}

task_list_ids() {
	if [[ -d "$TASKS_DIR" ]]; then
		local d
		for d in "$TASKS_DIR"/*; do
			[[ -d "$d" ]] || continue
			basename "$d"
		done | sort
	fi
}

task_status() {
	local task_id=$1
	task_get "$task_id" "status" "pending"
}

task_is_ready() {
	local task_id=$1
	local status
	status=$(task_status "$task_id")
	[[ "$status" == "pending" ]] || return 1

	local deps
	deps=$(task_get "$task_id" "deps" "")
	if [[ -z "$deps" ]]; then
		return 0
	fi

	local dep dep_status
	while IFS=',' read -ra dep_arr; do
		for dep in "${dep_arr[@]}"; do
			dep=$(printf '%s' "$dep" | tr -d '[:space:]')
			[[ -z "$dep" ]] && continue
			dep_status=$(task_status "$dep")
			if [[ "$dep_status" != "merged" ]]; then
				return 1
			fi
		done
	done <<<"$deps"
	return 0
}

# --- Logging ---

log_event() {
	local level=$1
	shift
	local msg="$*"
	local ts
	ts=$(now_iso)
	printf '[%s] [%s] %s\n' "$ts" "$level" "$msg" >>"$ORCHD_DIR/orchd.log"
	if [[ "$level" == "ERROR" ]]; then
		printf '\033[31m[%s] %s\033[0m\n' "$level" "$msg" >&2
	elif [[ "$level" == "WARN" ]]; then
		printf '\033[33m[%s] %s\033[0m\n' "$level" "$msg" >&2
	fi
}

# --- Timestamps ---

now_iso() {
	date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# --- String utilities ---

replace_token() {
	local input=$1
	local token=$2
	local replacement=$3

	awk -v token="$token" -v replacement="$replacement" '
		{
			line = $0
			out = ""
			while ((idx = index(line, token)) > 0) {
				out = out substr(line, 1, idx - 1) replacement
				line = substr(line, idx + length(token))
			}
			print out line
		}
	' <<<"$input"
}

# --- Worktree management ---

worktree_create() {
	local repo_dir=$1
	local branch=$2
	local worktree_path=$3

	if [[ -d "$worktree_path" ]]; then
		log_event "WARN" "worktree already exists: $worktree_path"
		return 0
	fi

	local base_branch
	base_branch=$(config_get "base_branch" "main")

	git -C "$repo_dir" worktree add -b "$branch" "$worktree_path" "$base_branch" 2>/dev/null || {
		# Branch may already exist
		git -C "$repo_dir" worktree add "$worktree_path" "$branch" 2>/dev/null || {
			log_event "ERROR" "failed to create worktree: $worktree_path"
			return 1
		}
	}
	log_event "INFO" "worktree created: $worktree_path (branch: $branch)"
}

worktree_remove() {
	local repo_dir=$1
	local worktree_path=$2

	if [[ -d "$worktree_path" ]]; then
		git -C "$repo_dir" worktree remove --force "$worktree_path" 2>/dev/null || true
		log_event "INFO" "worktree removed: $worktree_path"
	fi
}
