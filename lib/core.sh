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
				emitted = 0
				last_dot = 0
				for (i = 1; i <= length(wanted); i++) {
					if (substr(wanted, i, 1) == ".") {
						last_dot = i
					}
				}
				if (last_dot > 0) {
					wanted_section = substr(wanted, 1, last_dot - 1)
					wanted_key = substr(wanted, last_dot + 1)
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
				if (sec == "worker") return 1
				if (sec == "orchestrator") return 2
				if (sec == "project") return 3
				if (sec == "quality") return 4
				if (sec ~ /^runners\./) return 5
				if (sec == "") return 6
				return 7
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
					emitted = 1
					print best_val
					exit
				}
			}

			END {
				if (emitted == 0 && best_rank < 999) print best_val
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

# --- Agent policy docs ---

doc_template_content() {
	local name=$1
	if [[ -n "${ORCHD_LIB_DIR:-}" ]]; then
		local candidate="$ORCHD_LIB_DIR/../$name"
		if [[ -f "$candidate" ]]; then
			cat "$candidate"
			return 0
		fi
	fi

	case "$name" in
	AGENTS.md)
		cat <<'EOF'
# AGENTS.md

Shared rules for all AI agents in this repository.

## Role Routing (Mandatory)

1. Always read this file before any action.
2. If MODE is ORCHESTRATOR, you MUST read ORCHESTRATOR.md next.
3. If MODE is WORKER, you MUST read WORKER.md next.
4. If MODE is REVIEWER, follow the review task instructions and do not change code unless explicitly requested.
5. If MODE is not provided, infer it from the task:
   - Review/analysis tasks -> REVIEWER
   - Planning/coordination tasks -> ORCHESTRATOR
   - Implementation tasks -> WORKER
   - If still unclear, ask a single clarification question.

## Global Rules

- Do not leak secrets or credentials.
- Stay within the assigned task scope.
- Do not merge to the base branch; the orchestrator handles merges.
- Commit only to your task branch/worktree.
- Create TASK_REPORT.md at the repo/worktree root with:
  - Summary of changes
  - Files modified/created
  - Tests run (commands + results)
  - Risks/notes

## Acknowledgement

- Your first response must start with:
  - ACK: AGENTS.md read
  - and ACK: ORCHESTRATOR.md read OR ACK: WORKER.md read OR ACK: REVIEWER mode
- Exception: If strict output formatting is required, do not add ACK lines.
EOF
		;;
	ORCHESTRATOR.md)
		cat <<'EOF'
# ORCHESTRATOR.md

Operational rules for the orchestrator role.

## Responsibilities

- Break down work into a dependency DAG with small, parallelizable tasks.
- Launch agents only when dependencies are satisfied.
- Enforce quality gates (lint/test/build/evidence) before merge.
- Merge in dependency order, never force-merge.
- Keep scope boundaries clear between tasks.

## Orchestration Flow

1. Plan: define tasks with clear acceptance criteria.
2. Spawn: create worktrees and start agents in parallel where safe.
3. Monitor: track status and blockers.
4. Check: verify evidence and quality gates.
5. Merge: integrate in dependency order; resolve conflicts carefully.

## Safety

- Do not edit code in agent worktrees unless explicitly asked to fix.
- Do not skip quality gates unless explicitly authorized.
- Never push secrets into prompts or commits.
EOF
		;;
	WORKER.md)
		cat <<'EOF'
# WORKER.md

Operational rules for task-executing agents.

## Scope and Safety

- Work only within the provided worktree path.
- Follow the task description and acceptance criteria precisely.
- Do not modify unrelated files or change project-wide configs.
- Do not merge to the base branch; the orchestrator handles merges.
- Do not expose secrets or credentials.

## Quality Expectations

- Run the most relevant lint/test/build commands available.
- If a command cannot run, explain why in TASK_REPORT.md.
- Keep commits focused with clear messages.

## Required Deliverable

Create TASK_REPORT.md at the worktree root with:

- Summary of changes
- Files modified/created
- Tests run (commands + results)
- Evidence notes (pass/fail)
- Risks/notes
EOF
		;;
	CLAUDE.md)
		cat <<'EOF'
Read AGENTS.md first and follow the role routing rules.
EOF
		;;
	OPENCODE.md)
		cat <<'EOF'
Read AGENTS.md first and follow the role routing rules.
EOF
		;;
	*)
		return 1
		;;
	esac
}

write_doc_file() {
	local dest=$1
	local mode=$2
	local name
	name=$(basename "$dest")
	local tmp
	ORCHD_DOC_STATUS=""

	tmp=$(mktemp)
	if ! doc_template_content "$name" >"$tmp"; then
		rm -f "$tmp"
		return 1
	fi

	if [[ "$mode" == "if_missing" ]] && [[ -f "$dest" ]]; then
		ORCHD_DOC_STATUS="exists"
		rm -f "$tmp"
		return 0
	fi

	if [[ -f "$dest" ]]; then
		if cmp -s "$tmp" "$dest"; then
			ORCHD_DOC_STATUS="unchanged"
			rm -f "$tmp"
			return 0
		fi
		cp "$dest" "${dest}.bak"
		ORCHD_DOC_STATUS="updated"
	else
		ORCHD_DOC_STATUS="created"
	fi

	mv "$tmp" "$dest"
}

ensure_agent_docs() {
	local dir=$1
	local doc
	for doc in AGENTS.md ORCHESTRATOR.md WORKER.md CLAUDE.md OPENCODE.md; do
		write_doc_file "$dir/$doc" "if_missing" || die "failed to write $doc"
	done
}

refresh_agent_docs() {
	local dir=$1
	local doc
	for doc in AGENTS.md ORCHESTRATOR.md WORKER.md CLAUDE.md OPENCODE.md; do
		write_doc_file "$dir/$doc" "refresh" || die "failed to write $doc"
		case "$ORCHD_DOC_STATUS" in
		created)
			printf 'created: %s\n' "$doc"
			;;
		updated)
			printf 'updated: %s (backup: %s.bak)\n' "$doc" "$doc"
			;;
		unchanged)
			printf 'unchanged: %s\n' "$doc"
			;;
		exists)
			printf 'exists: %s\n' "$doc"
			;;
		esac
	done
}

# --- Quality command detection ---

quality_detect_reset() {
	ORCHD_DETECTED_STACK=""
	ORCHD_DETECTED_LINT_CMD=""
	ORCHD_DETECTED_TEST_CMD=""
	ORCHD_DETECTED_BUILD_CMD=""
	ORCHD_DETECTED_NOTES=""
	ORCHD_DETECTED_SCORE="-1"
	ORCHD_DETECTED_STACK_COUNT="0"
}

quality_detect_note() {
	local msg=$1
	if [[ -n "$msg" ]]; then
		if [[ -n "$ORCHD_DETECTED_NOTES" ]]; then
			ORCHD_DETECTED_NOTES+=$'\n'
		fi
		ORCHD_DETECTED_NOTES+="$msg"
	fi
}

detect_node_pm() {
	local repo_dir=$1
	if [[ -f "$repo_dir/pnpm-lock.yaml" ]]; then
		printf '%s\n' "pnpm"
	elif [[ -f "$repo_dir/yarn.lock" ]]; then
		printf '%s\n' "yarn"
	elif [[ -f "$repo_dir/bun.lockb" ]] || [[ -f "$repo_dir/bun.lock" ]]; then
		printf '%s\n' "bun"
	elif [[ -f "$repo_dir/package-lock.json" ]]; then
		printf '%s\n' "npm"
	else
		printf '%s\n' "npm"
	fi
}

node_run_cmd() {
	local pm=$1
	local script=$2
	case "$pm" in
	npm)
		printf 'npm run %s\n' "$script"
		;;
	yarn)
		printf 'yarn run %s\n' "$script"
		;;
	pnpm)
		printf 'pnpm run %s\n' "$script"
		;;
	bun)
		printf 'bun run %s\n' "$script"
		;;
	*)
		printf 'npm run %s\n' "$script"
		;;
	esac
}

node_script_exists() {
	local pkg_path=$1
	local script=$2

	if command -v node >/dev/null 2>&1; then
		if NODE_PKG="$pkg_path" NODE_SCRIPT="$script" node -e '
const fs = require("fs");
try {
  const p = JSON.parse(fs.readFileSync(process.env.NODE_PKG, "utf8"));
  const ok = !!(p.scripts && Object.prototype.hasOwnProperty.call(p.scripts, process.env.NODE_SCRIPT));
  process.exit(ok ? 0 : 1);
} catch (e) {
  process.exit(2);
}
' >/dev/null 2>&1; then
			return 0
		else
			return $?
		fi
	fi

	if command -v jq >/dev/null 2>&1; then
		if jq -e --arg s "$script" '.scripts and (.scripts[$s] != null)' "$pkg_path" >/dev/null 2>&1; then
			return 0
		else
			return $?
		fi
	fi

	if command -v python3 >/dev/null 2>&1; then
		if PY_PKG="$pkg_path" PY_SCRIPT="$script" python3 - <<'PY' >/dev/null 2>&1; then
import json
import os
import sys
try:
    with open(os.environ["PY_PKG"], "r", encoding="utf-8") as f:
        data = json.load(f)
    scripts = data.get("scripts", {})
    sys.exit(0 if os.environ["PY_SCRIPT"] in scripts else 1)
except Exception:
    sys.exit(2)
PY
			return 0
		else
			return $?
		fi
	fi

	if command -v python >/dev/null 2>&1; then
		if PY_PKG="$pkg_path" PY_SCRIPT="$script" python - <<'PY' >/dev/null 2>&1; then
import json
import os
import sys
try:
    with open(os.environ["PY_PKG"], "r", encoding="utf-8") as f:
        data = json.load(f)
    scripts = data.get("scripts", {})
    sys.exit(0 if os.environ["PY_SCRIPT"] in scripts else 1)
except Exception:
    sys.exit(2)
PY
			return 0
		else
			return $?
		fi
	fi

	return 2
}

wrapper_cmd() {
	local path=$1
	local base
	base=$(basename "$path")
	if [[ -x "$path" ]]; then
		printf './%s\n' "$base"
	else
		printf 'sh ./%s\n' "$base"
	fi
}

quality_detect_cmds() {
	local repo_dir=${1:-$PROJECT_ROOT}
	quality_detect_reset

	local best_score=-1
	local best_stack=""
	local best_lint=""
	local best_test=""
	local best_build=""
	local best_notes=""
	local stack_count=0

	# Node
	if [[ -f "$repo_dir/package.json" ]]; then
		stack_count=$((stack_count + 1))
		local lint="" test="" build="" notes="" score=0
		local pm pkg rc
		pm=$(detect_node_pm "$repo_dir")
		pkg="$repo_dir/package.json"

		node_script_exists "$pkg" "lint"
		rc=$?
		if [[ "$rc" == "0" ]]; then
			lint=$(node_run_cmd "$pm" "lint")
			score=$((score + 1))
		elif ((rc >= 2)); then
			notes="node: cannot parse package.json for lint"
		fi

		node_script_exists "$pkg" "test"
		rc=$?
		if [[ "$rc" == "0" ]]; then
			test=$(node_run_cmd "$pm" "test")
			score=$((score + 1))
		elif ((rc >= 2)); then
			if [[ -n "$notes" ]]; then
				notes+=$'\n'
			fi
			notes+="node: cannot parse package.json for test"
		fi

		node_script_exists "$pkg" "build"
		rc=$?
		if [[ "$rc" == "0" ]]; then
			build=$(node_run_cmd "$pm" "build")
			score=$((score + 1))
		elif ((rc >= 2)); then
			if [[ -n "$notes" ]]; then
				notes+=$'\n'
			fi
			notes+="node: cannot parse package.json for build"
		fi

		if ((score > best_score)); then
			best_score=$score
			best_stack="node"
			best_lint="$lint"
			best_test="$test"
			best_build="$build"
			best_notes="$notes"
		fi
	fi

	# Python
	if [[ -f "$repo_dir/pyproject.toml" ]] || [[ -f "$repo_dir/requirements.txt" ]] || [[ -f "$repo_dir/poetry.lock" ]]; then
		stack_count=$((stack_count + 1))
		local lint="" test="" build="" notes="" score=0
		if command -v ruff >/dev/null 2>&1; then
			lint="ruff check ."
			score=$((score + 1))
		fi
		if command -v pytest >/dev/null 2>&1; then
			test="pytest"
			score=$((score + 1))
		fi
		if ((score > best_score)); then
			best_score=$score
			best_stack="python"
			best_lint="$lint"
			best_test="$test"
			best_build="$build"
			best_notes="$notes"
		fi
	fi

	# Go
	if [[ -f "$repo_dir/go.mod" ]]; then
		stack_count=$((stack_count + 1))
		local lint="" test="" build="" notes="" score=0
		if command -v go >/dev/null 2>&1; then
			test="go test ./..."
			build="go build ./..."
			lint="go vet ./..."
			score=$((score + 3))
		fi
		if ((score > best_score)); then
			best_score=$score
			best_stack="go"
			best_lint="$lint"
			best_test="$test"
			best_build="$build"
			best_notes="$notes"
		fi
	fi

	# Rust
	if [[ -f "$repo_dir/Cargo.toml" ]]; then
		stack_count=$((stack_count + 1))
		local lint="" test="" build="" notes="" score=0
		if command -v cargo >/dev/null 2>&1; then
			test="cargo test"
			build="cargo build"
			score=$((score + 2))
			if command -v cargo-clippy >/dev/null 2>&1; then
				lint="cargo clippy -- -D warnings"
				score=$((score + 1))
			fi
		fi
		if ((score > best_score)); then
			best_score=$score
			best_stack="rust"
			best_lint="$lint"
			best_test="$test"
			best_build="$build"
			best_notes="$notes"
		fi
	fi

	# Java (Maven/Gradle)
	if [[ -f "$repo_dir/pom.xml" ]] || [[ -f "$repo_dir/build.gradle" ]] || [[ -f "$repo_dir/build.gradle.kts" ]]; then
		stack_count=$((stack_count + 1))
		local lint="" test="" build="" notes="" score=0
		if [[ -f "$repo_dir/mvnw" ]]; then
			local mvnw_cmd
			mvnw_cmd=$(wrapper_cmd "$repo_dir/mvnw")
			test="$mvnw_cmd -q test"
			build="$mvnw_cmd -q -DskipTests package"
			score=$((score + 2))
		elif [[ -f "$repo_dir/gradlew" ]]; then
			local gradle_cmd
			gradle_cmd=$(wrapper_cmd "$repo_dir/gradlew")
			test="$gradle_cmd test"
			build="$gradle_cmd build"
			score=$((score + 2))
		elif command -v mvn >/dev/null 2>&1; then
			test="mvn -q test"
			build="mvn -q -DskipTests package"
			score=$((score + 2))
		elif command -v gradle >/dev/null 2>&1; then
			test="gradle test"
			build="gradle build"
			score=$((score + 2))
		fi
		if ((score > best_score)); then
			best_score=$score
			best_stack="java"
			best_lint="$lint"
			best_test="$test"
			best_build="$build"
			best_notes="$notes"
		fi
	fi

	# shellcheck disable=SC2034
	ORCHD_DETECTED_STACK="$best_stack"
	# shellcheck disable=SC2034
	ORCHD_DETECTED_LINT_CMD="$best_lint"
	# shellcheck disable=SC2034
	ORCHD_DETECTED_TEST_CMD="$best_test"
	# shellcheck disable=SC2034
	ORCHD_DETECTED_BUILD_CMD="$best_build"
	# shellcheck disable=SC2034
	ORCHD_DETECTED_SCORE="$best_score"
	# shellcheck disable=SC2034
	ORCHD_DETECTED_STACK_COUNT="$stack_count"
	# shellcheck disable=SC2034
	ORCHD_DETECTED_NOTES="$best_notes"

	if ((stack_count > 1)) && [[ -n "$best_stack" ]]; then
		quality_detect_note "multiple stacks detected; using $best_stack"
	fi
	if ((best_score == 0)) && [[ -n "$best_stack" ]]; then
		quality_detect_note "no lint/test/build commands detected for $best_stack"
	fi
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
