#!/usr/bin/env bash
# lib/core.sh - Shared utilities, config loading, state management, memory bank, idea queue
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
2. If MODE is ORCHESTRATOR, you MUST read ORCHESTRATOR.md and orchestrator-runbook.md next.
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
- If MODE is ORCHESTRATOR, also include:
  - ACK: orchestrator-runbook.md read
- Exception: If strict output formatting is required, do not add ACK lines.
EOF
		;;
	ORCHESTRATOR.md)
		cat <<'EOF'
# ORCHESTRATOR.md

Operational guide for AI orchestrators.

## Required Reading

- Read `orchestrator-runbook.md` for detailed operational guidance.

## Memory Bank

Before planning or making decisions, read `docs/memory/` for project context:
- `projectbrief.md` — Project goals, scope, and product context
- `activeContext.md` — Current work focus, recent changes, active decisions
- `progress.md` — What works, what's left, known issues
- `systemPatterns.md` — Architecture, patterns, component relationships
- `techContext.md` — Stack, dependencies, dev environment
- `lessons/` — Per-task learnings from completed work

If `docs/memory/` does not exist, run `orchd memory init` or proceed without it.

## Objective

Drive the project to completion by coordinating workers through `orchd`.
You own planning, sequencing, retries, verification, and integration.

## Working Model

- Orchestrator = the AI currently driving the terminal session.
- Workers = task executors launched by `orchd` (default runner is from `[worker].runner`).
- Run autonomously by default; ask the user only when blocked by missing requirements/credentials.

## Project Context

Before planning, scan the repository for existing docs (examples):
- PHASES.md, PRD.md, ROADMAP.md, TODO.md, BACKLOG.md
- docs/ or planning directories with requirements, contracts, or runbooks

Use these to understand current state, remaining work, constraints, and acceptance criteria.

## Core Commands

- `orchd state --json`: machine-friendly snapshot for decision making.
- `orchd plan "<description>"`: AI-generated task DAG.
- `orchd plan --file <path>` / `orchd plan --stdin`: import externally-produced task DAG.

## Task-Specific Quality Commands (Optional)

Task blocks can optionally include `LINT_CMD`, `TEST_CMD`, and `BUILD_CMD`.
If present, `orchd check` will use them for that task (override > global config > auto-detect).
- `orchd spawn --all [--runner <runner>]`: start ready tasks.
- `orchd check --all`: evaluate completed/finished tasks.
- `orchd merge --all`: integrate done tasks in dependency order.
- `orchd resume <task-id> [reason]`: continue failed/stuck tasks.
- `orchd autopilot`: run the built-in autonomous loop.
- `orchd autopilot --daemon [poll]`: run autonomously in background (recommended for long runs).
- `orchd autopilot --status|--stop|--logs`: manage the daemon.

## Suggested Loop

1. Read state (`orchd state --json`).
2. If no tasks exist: create/import a plan.
3. Spawn ready tasks up to parallel limit.
4. Check finished tasks.
5. Merge tasks that are `done` and dependency-ready.
6. Retry/resume failed tasks with a focused reason.
7. When waiting, use `orchd await --all` instead of `sleep`.
8. Repeat until all tasks are terminal (`merged` or explicit blocker states).

## Decision Rules

- Prefer many small dependency-safe tasks over large monolith tasks.
- Keep workers scoped: one clear goal per task with concrete acceptance criteria.
- Use `state --json` as source of truth for "what next".
- If a task needs user input, keep progress moving on other unblocked tasks.

## Deliverable Expectations

- Every worker task should leave clear evidence (`TASK_REPORT.md`, commits, checks).
- Merge only tasks that pass project quality gates.
- Preserve clean branch history and dependency order during integration.
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
- Do not log or commit PII, tokens, or API keys.

## Quality Expectations

- Run the most relevant lint/test/build commands available.
- If a command cannot run, explain why in TASK_REPORT.md.
- Keep commits focused with clear messages.
- Add tests for new functionality when possible.

## Evidence Format (Mandatory)

All test/lint/build results in TASK_REPORT.md must use this format:

```text
EVIDENCE:
- CMD: <command>
  RESULT: PASS|FAIL
  OUTPUT: <brief summary, max 3 lines>
```

## Rollback Note

Include a rollback section in TASK_REPORT.md:

- What triggers a rollback (e.g. test regression, contract break)
- How to revert (e.g. `git revert <sha>`, remove migration)

## Definition of Done

A task is `done` only when ALL of these are true:

1. All acceptance criteria are met.
2. Lint passes (no new warnings).
3. Relevant tests pass.
4. No out-of-scope changes.
5. TASK_REPORT.md is complete with evidence + rollback note.
6. Commits are clean and focused.

## Blocker Protocol

- If blocked, create `.orchd_needs_input.md` at the worktree root explaining what is needed.
- If a dependency is missing, document it and exit cleanly.

## Required Deliverable

Create TASK_REPORT.md at the worktree root with:

- Summary of changes
- Files modified/created
- Evidence (using the format above)
- Rollback note
- Risks/notes

Notes:

- Do not commit TASK_REPORT.md or .orchd_needs_input.md; they are treated as local artifacts.
- orchd archives TASK_REPORT.md into `.orchd/tasks/<task-id>/` during `orchd check`.
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
	orchestrator-runbook.md)
		cat <<'EOF'
# Orchestrator Runbook

This runbook was not found in the current orchd installation.
Reinstall orchd from the repository to restore the full runbook:
https://github.com/Frexxis/orchd
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
	for doc in AGENTS.md ORCHESTRATOR.md orchestrator-runbook.md WORKER.md CLAUDE.md OPENCODE.md; do
		write_doc_file "$dir/$doc" "if_missing" || die "failed to write $doc"
	done
}

refresh_agent_docs() {
	local dir=$1
	local doc
	for doc in AGENTS.md ORCHESTRATOR.md orchestrator-runbook.md WORKER.md CLAUDE.md OPENCODE.md; do
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

# ============================================================================
# Memory Bank — Cline-inspired structured project memory for multi-agent use
# ============================================================================
#
# docs/memory/
# ├── projectbrief.md    — Project goals, scope, product context (user/init)
# ├── systemPatterns.md  — Architecture, patterns, component relationships
# ├── techContext.md      — Stack, deps, dev environment, constraints
# ├── activeContext.md    — Current focus, recent changes, active decisions
# ├── progress.md         — What works, what's left, known issues
# └── lessons/            — Per-task learnings (auto-written by workers)
#       ├── task-auth.md
#       └── ...

MEMORY_BANK_FILES=(projectbrief.md systemPatterns.md techContext.md activeContext.md progress.md)

memory_dir() {
	local dir="${PROJECT_ROOT}/docs/memory"
	mkdir -p "$dir" "$dir/lessons"
	printf '%s\n' "$dir"
}

memory_ensure_scaffold() {
	local mem_dir
	mem_dir=$(memory_dir)

	if [[ ! -f "$mem_dir/projectbrief.md" ]]; then
		local name desc
		name=$(config_get "project.name" "")
		desc=$(config_get "project.description" "")
		cat >"$mem_dir/projectbrief.md" <<EOF
# Project Brief

## Project Name
${name:-$(basename "$PROJECT_ROOT")}

## Description
${desc:-No description provided. Edit this file to define project goals, scope, and product context.}

## Goals
- (define project goals here)

## Scope
- IN: (what is in scope)
- OUT: (what is out of scope)

## Product Context
- Why this project exists: (fill in)
- Problems it solves: (fill in)
- User experience goals: (fill in)
EOF
	fi

	if [[ ! -f "$mem_dir/systemPatterns.md" ]]; then
		cat >"$mem_dir/systemPatterns.md" <<'EOF'
# System Patterns

## Architecture
- (describe system architecture)

## Key Technical Decisions
- (list decisions and rationale)

## Design Patterns in Use
- (patterns used in the codebase)

## Component Relationships
- (how components interact)
EOF
	fi

	if [[ ! -f "$mem_dir/techContext.md" ]]; then
		cat >"$mem_dir/techContext.md" <<'EOF'
# Tech Context

## Technologies Used
- (list stack components)

## Development Setup
- (how to set up the dev environment)

## Technical Constraints
- (limitations, compatibility requirements)

## Dependencies
- (key dependencies)
EOF
	fi

	if [[ ! -f "$mem_dir/activeContext.md" ]]; then
		cat >"$mem_dir/activeContext.md" <<'EOF'
# Active Context

## Current Focus
- (what is being worked on now)

## Recent Changes
- (latest completed work)

## Next Steps
- (upcoming work)

## Active Decisions
- (decisions under consideration)
EOF
	fi

	if [[ ! -f "$mem_dir/progress.md" ]]; then
		cat >"$mem_dir/progress.md" <<'EOF'
# Progress

## What Works
- (completed and verified functionality)

## What's Left to Build
- (remaining work)

## Current Status
- Project initialized

## Known Issues
- (none yet)
EOF
	fi
}

# Read all memory bank files and compose a context string for agent prompts.
# Respects a configurable character limit (memory_max_chars, default 12000).
memory_read_context() {
	local mem_dir="${PROJECT_ROOT}/docs/memory"
	if [[ ! -d "$mem_dir" ]]; then
		return 0
	fi

	local max_chars
	max_chars=$(config_get "memory_max_chars" "12000")
	if ! [[ "$max_chars" =~ ^[0-9]+$ ]]; then
		max_chars=12000
	fi

	local context=""
	local file_name

	# 1. Core memory files (always included, in hierarchy order)
	for file_name in "${MEMORY_BANK_FILES[@]}"; do
		if [[ -f "$mem_dir/$file_name" ]]; then
			local content
			content=$(cat "$mem_dir/$file_name" 2>/dev/null || true)
			if [[ -n "$content" ]]; then
				context+="--- ${file_name} ---"$'\n'"${content}"$'\n\n'
			fi
		fi
	done

	# 2. Lessons (newest first, appended until budget exhausted)
	if [[ -d "$mem_dir/lessons" ]]; then
		local lesson_files=()
		local lf
		while IFS= read -r lf; do
			[[ -n "$lf" ]] && lesson_files+=("$lf")
		done < <(ls -t "$mem_dir/lessons"/*.md 2>/dev/null || true)

		if ((${#lesson_files[@]} > 0)); then
			context+="--- lessons (from completed tasks) ---"$'\n'
			for lf in "${lesson_files[@]}"; do
				local lcontent
				lcontent=$(cat "$lf" 2>/dev/null || true)
				if [[ -n "$lcontent" ]]; then
					context+=$'\n'"${lcontent}"$'\n'
				fi
				# Check budget after each lesson
				if ((${#context} >= max_chars)); then
					break
				fi
			done
		fi
	fi

	# Truncate if over budget
	if ((${#context} > max_chars)); then
		context="${context:0:max_chars}"
		context+=$'\n[MEMORY TRUNCATED: limit reached]'
	fi

	printf '%s' "$context"
}

# Write a lesson entry for a completed task.
# Called by the orchestrator after successful merge.
# Sources: TASK_REPORT.md (archived copy in task state dir).
memory_write_lesson() {
	local task_id=$1
	local mem_dir
	mem_dir=$(memory_dir)
	local lesson_file
	lesson_file="$mem_dir/lessons/${task_id}.md"

	# Preserve worker-authored lessons if they already exist.
	if [[ -s "$lesson_file" ]]; then
		log_event "INFO" "memory: lesson exists for $task_id (preserved)"
		return 0
	fi

	local title description
	title=$(task_get "$task_id" "title" "$task_id")
	description=$(task_get "$task_id" "description" "")

	# Find the archived task report
	local report_content=""
	local attempts
	attempts=$(task_get "$task_id" "attempts" "0")
	if ! [[ "$attempts" =~ ^[0-9]+$ ]]; then
		attempts=0
	fi
	local report_file
	report_file=$(task_get "$task_id" "task_report_file" "")
	if [[ -n "$report_file" ]] && [[ -f "$report_file" ]]; then
		report_content=$(cat "$report_file" 2>/dev/null || true)
	fi

	# Also check worktree for TASK_REPORT.md if not archived yet
	if [[ -z "$report_content" ]]; then
		local worktree
		worktree=$(task_get "$task_id" "worktree" "")
		if [[ -n "$worktree" ]] && [[ -f "$worktree/TASK_REPORT.md" ]]; then
			report_content=$(cat "$worktree/TASK_REPORT.md" 2>/dev/null || true)
		fi
	fi

	local ts
	ts=$(now_iso)

	cat >"$lesson_file" <<EOF
### Task: ${task_id}
**Title:** ${title}
**Merged:** ${ts}
**Description:** ${description}

#### Summary
$(if [[ -n "$report_content" ]]; then
		# Extract summary: everything before EVIDENCE block (or first 20 lines)
		printf '%s\n' "$report_content" | awk '/^EVIDENCE:/{exit} {print}' | head -n 20
	else
		printf 'No task report available.\n'
	fi)

#### Evidence
$(if [[ -n "$report_content" ]]; then
		printf '%s\n' "$report_content" | awk '/^EVIDENCE:/,0' | head -n 15
	else
		printf 'No evidence captured.\n'
	fi)
EOF

	log_event "INFO" "memory: lesson written for $task_id"
}

# Update progress.md with current task state snapshot.
# Called by orchestrator after merge or autopilot cycle.
memory_update_progress() {
	local mem_dir
	mem_dir=$(memory_dir)

	local ts
	ts=$(now_iso)

	local total=0 merged=0 failed=0 pending=0 running=0 needs_input=0
	local merged_list="" pending_list="" failed_list=""
	local task_id status
	while IFS= read -r task_id; do
		[[ -z "$task_id" ]] && continue
		total=$((total + 1))
		status=$(task_status "$task_id")
		local title
		title=$(task_get "$task_id" "title" "$task_id")
		case "$status" in
		merged)
			merged=$((merged + 1))
			merged_list+="- [x] ${task_id}: ${title}"$'\n'
			;;
		failed)
			failed=$((failed + 1))
			failed_list+="- [!] ${task_id}: ${title}"$'\n'
			;;
		pending)
			pending=$((pending + 1))
			pending_list+="- [ ] ${task_id}: ${title}"$'\n'
			;;
		running) running=$((running + 1)) ;;
		needs_input) needs_input=$((needs_input + 1)) ;;
		esac
	done <<<"$(task_list_ids)"

	cat >"$mem_dir/progress.md" <<EOF
# Progress

*Last updated: ${ts}*

## Summary
- Total tasks: ${total}
- Merged: ${merged}
- Pending: ${pending}
- Running: ${running}
- Failed: ${failed}
- Needs input: ${needs_input}

## Completed (merged)
${merged_list:-  (none yet)}

## Remaining
${pending_list:-  (none)}

## Issues
${failed_list:-  (none)}
EOF
}

# Update activeContext.md with current orchestration state.
# Called at the end of autopilot cycles.
memory_update_active_context() {
	local mem_dir
	mem_dir=$(memory_dir)

	local ts
	ts=$(now_iso)

	local focus=""
	local recent=""
	local next=""

	# Gather running tasks as current focus
	local task_id status
	while IFS= read -r task_id; do
		[[ -z "$task_id" ]] && continue
		status=$(task_status "$task_id")
		local title
		title=$(task_get "$task_id" "title" "$task_id")
		case "$status" in
		running)
			focus+="- ${task_id}: ${title} (running)"$'\n'
			;;
		pending)
			if task_is_ready "$task_id"; then
				next+="- ${task_id}: ${title} (ready to spawn)"$'\n'
			else
				next+="- ${task_id}: ${title} (waiting for deps)"$'\n'
			fi
			;;
		merged)
			recent+="- ${task_id}: ${title} (merged)"$'\n'
			;;
		esac
	done <<<"$(task_list_ids)"

	cat >"$mem_dir/activeContext.md" <<EOF
# Active Context

*Last updated: ${ts}*

## Current Focus
${focus:-  (no tasks currently running)}

## Recent Changes
${recent:-  (no tasks merged yet)}

## Next Steps
${next:-  (no pending tasks)}

## Active Decisions
- (auto-generated context — edit manually for important decisions)
EOF
}

# ============================================================================
# Idea Queue — Persistent idea backlog for continuous autopilot operation
# ============================================================================
#
# Ideas are stored in .orchd/queue.md as a checklist:
#   - [ ] 2024-01-15T10:30:00Z Build user dashboard
#   - [x] 2024-01-15T09:00:00Z Add auth middleware (completed)

queue_file() {
	printf '%s\n' "$ORCHD_DIR/queue.md"
}

queue_ensure() {
	local qf
	qf=$(queue_file)
	if [[ ! -f "$qf" ]]; then
		cat >"$qf" <<'EOF'
# orchd Idea Queue
# Add ideas with: orchd idea "your idea here"
# Autopilot will pick them up automatically when current tasks complete.
EOF
	fi
}

queue_push() {
	local idea=$1
	queue_ensure
	local qf ts
	qf=$(queue_file)
	ts=$(now_iso)
	printf -- '- [ ] %s %s\n' "$ts" "$idea" >>"$qf"
	log_event "INFO" "idea queued: $idea"
}

# Pop the first uncompleted idea. Prints the idea text (without timestamp).
# Returns 1 if no ideas remain.
queue_pop() {
	local qf
	qf=$(queue_file)
	[[ -f "$qf" ]] || return 1

	local idea_line=""
	local idea_text=""
	local line_num=0
	local found_num=0

	while IFS= read -r line; do
		line_num=$((line_num + 1))
		if [[ "$line" =~ ^-\ \[\ \]\ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\ (.+)$ ]]; then
			if [[ -z "$idea_line" ]]; then
				idea_line="$line"
				idea_text="${BASH_REMATCH[1]}"
				found_num=$line_num
			fi
		fi
	done <"$qf"

	if [[ -z "$idea_text" ]]; then
		return 1
	fi

	# Mark as popped: - [ ] -> - [>] (in-progress)
	local tmp
	tmp=$(mktemp)
	awk -v target="$found_num" '
		NR == target {
			sub(/^- \[ \]/, "- [>]")
		}
		{ print }
	' "$qf" >"$tmp"
	mv "$tmp" "$qf"

	printf '%s\n' "$idea_text"
	log_event "INFO" "idea popped: $idea_text"
	return 0
}

# Mark the currently in-progress idea as completed.
queue_complete_current() {
	local qf
	qf=$(queue_file)
	[[ -f "$qf" ]] || return 0

	local tmp
	tmp=$(mktemp)
	# Only mark the first [>] as [x]; leave others untouched
	awk '
		!done && /^- \[>\]/ {
			sub(/^- \[>\]/, "- [x]")
			done = 1
		}
		{ print }
	' "$qf" >"$tmp"
	mv "$tmp" "$qf"
}

# Count pending (uncompleted) ideas in the queue.
queue_count() {
	local qf
	qf=$(queue_file)
	[[ -f "$qf" ]] || {
		printf '0\n'
		return 0
	}

	local count=0
	while IFS= read -r line; do
		if [[ "$line" =~ ^-\ \[\ \]\ .+ ]]; then
			count=$((count + 1))
		fi
	done <"$qf"
	printf '%d\n' "$count"
}

# Count in-progress ideas (marked with [>]).
queue_in_progress_count() {
	local qf
	qf=$(queue_file)
	[[ -f "$qf" ]] || {
		printf '0\n'
		return 0
	}

	local count=0
	while IFS= read -r line; do
		case "$line" in
		'- [>] '*) count=$((count + 1)) ;;
		esac
	done <"$qf"
	printf '%d\n' "$count"
}

# List all ideas with their status.
queue_list() {
	local qf
	qf=$(queue_file)
	if [[ ! -f "$qf" ]]; then
		printf 'no ideas queued (use: orchd idea "your idea")\n'
		return 0
	fi

	local pending=0 completed=0 in_progress=0
	while IFS= read -r line; do
		case "$line" in
		'- [ ] '*)
			pending=$((pending + 1))
			printf '  %s\n' "$line"
			;;
		'- [>] '*)
			in_progress=$((in_progress + 1))
			printf '  %s\n' "$line"
			;;
		'- [x] '*)
			completed=$((completed + 1))
			printf '  %s\n' "$line"
			;;
		esac
	done <"$qf"

	printf '\npending: %d  in-progress: %d  completed: %d\n' "$pending" "$in_progress" "$completed"
}

# ============================================================================
# Fleet — Multi-project management via ~/.orchd/fleet.toml
# ============================================================================

fleet_config_file() {
	printf '%s\n' "${ORCHD_STATE_DIR:-$HOME/.orchd}/fleet.toml"
}

# Parse fleet.toml and list project entries as "id<TAB>path" lines.
# Format:
#   [projects.myapi]
#   path = "/home/user/projects/my-api"
fleet_list_projects() {
	local cfg
	cfg=$(fleet_config_file)
	[[ -f "$cfg" ]] || return 1

	awk '
		function trim(s) {
			sub(/^[[:space:]]+/, "", s)
			sub(/[[:space:]]+$/, "", s)
			return s
		}
		/^[[:space:]]*\[projects\.[^]]+\]/ {
			sec = $0
			sub(/^[[:space:]]*\[projects\./, "", sec)
			sub(/\][[:space:]]*$/, "", sec)
			current_id = trim(sec)
			next
		}
		/^[[:space:]]*\[/ {
			current_id = ""
			next
		}
		current_id != "" && /^[[:space:]]*path[[:space:]]*=/ {
			val = $0
			sub(/^[^=]*=[[:space:]]*/, "", val)
			gsub(/^"/, "", val)
			gsub(/"[[:space:]]*(#.*)?$/, "", val)
			val = trim(val)
			if (val != "") {
				print current_id "\t" val
			}
		}
	' "$cfg"
}
