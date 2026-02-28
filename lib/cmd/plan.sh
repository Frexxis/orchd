#!/usr/bin/env bash
# lib/cmd/plan.sh - orchd plan command
# Uses AI to generate a task DAG from a project description

cmd_plan() {
	local description="$*"

	[[ -n "$description" ]] || die "usage: orchd plan \"<project description>\""

	require_project

	local runner
	runner=$(detect_runner)
	runner_validate "$runner"

	# Gather codebase context
	local context=""
	if [[ -d "$PROJECT_ROOT/src" ]] || [[ -d "$PROJECT_ROOT/lib" ]] || [[ -d "$PROJECT_ROOT/app" ]]; then
		context="Directory structure:\n$(find "$PROJECT_ROOT" -maxdepth 3 -not -path '*/.git/*' -not -path '*/.orchd/*' -not -path '*/node_modules/*' -not -path '*/.worktrees/*' | head -80)"
	else
		context="Directory structure:\n$(find "$PROJECT_ROOT" -maxdepth 2 -not -path '*/.git/*' -not -path '*/.orchd/*' | head -40)"
	fi

	# Check for package.json, Cargo.toml, etc. for stack detection
	local stack_files=""
	for f in package.json Cargo.toml go.mod pyproject.toml requirements.txt pom.xml build.gradle Makefile; do
		if [[ -f "$PROJECT_ROOT/$f" ]]; then
			stack_files="$stack_files\n--- $f ---\n$(head -30 "$PROJECT_ROOT/$f")"
		fi
	done
	if [[ -n "$stack_files" ]]; then
		context="$context\n\nDetected project files:$stack_files"
	fi

	# Build the planning prompt from template
	local template_file="$ORCHD_LIB_DIR/../templates/plan.prompt"
	if [[ ! -f "$template_file" ]]; then
		die "plan template not found: $template_file"
	fi

	local prompt
	prompt=$(cat "$template_file")
	prompt=${prompt//\{project_description\}/$description}
	prompt=${prompt//\{codebase_context\}/$context}

	printf 'generating task plan with %s...\n' "$runner"

	# Save prompt for debugging
	printf '%s\n' "$prompt" >"$ORCHD_DIR/last_plan_prompt.txt"

	# Execute via runner to get plan output
	local plan_output="$ORCHD_DIR/plan_output.txt"

	case "$runner" in
	codex)
		local codex_bin
		codex_bin=$(config_get "codex_bin" "codex")
		"$codex_bin" exec "$prompt" -C "$PROJECT_ROOT" --json 2>/dev/null |
			_extract_text_from_jsonl >"$plan_output" || {
			die "codex plan generation failed. Check $ORCHD_DIR/last_plan_prompt.txt"
		}
		;;
	claude)
		local claude_bin
		claude_bin=$(config_get "claude_bin" "claude")
		"$claude_bin" -p "$prompt" --output-format text 2>/dev/null >"$plan_output" || {
			die "claude plan generation failed"
		}
		;;
	opencode)
		opencode -p "$prompt" 2>/dev/null >"$plan_output" || {
			die "opencode plan generation failed"
		}
		;;
	aider)
		aider --message "$prompt" --yes --no-git 2>/dev/null >"$plan_output" || {
			die "aider plan generation failed"
		}
		;;
	esac

	# Parse the plan output into task state files
	_parse_plan_output "$plan_output"
}

# --- Extract text content from JSONL (codex output) ---
_extract_text_from_jsonl() {
	if command -v jq >/dev/null 2>&1; then
		jq -r 'select(.type=="item.completed" and .item.type=="agent_message") | .item.text // empty' 2>/dev/null
	else
		# Fallback: grep for text-like content
		grep -oP '"text"\s*:\s*"\K[^"]+' 2>/dev/null || cat
	fi
}

# --- Parse TASK blocks from plan output ---
_parse_plan_output() {
	local plan_file=$1
	local current_id=""
	local count=0

	# Clear existing tasks
	if [[ -d "$TASKS_DIR" ]] && [[ -n "$(ls -A "$TASKS_DIR" 2>/dev/null)" ]]; then
		printf 'warning: clearing existing task plan\n'
		rm -rf "${TASKS_DIR:?}"/*
	fi

	while IFS= read -r line; do
		case "$line" in
		TASK:*)
			current_id=$(printf '%s' "$line" | sed 's/^TASK:[[:space:]]*//' | tr -d '[:space:]')
			if [[ -n "$current_id" ]]; then
				mkdir -p "$TASKS_DIR/$current_id"
				task_set "$current_id" "status" "pending"
				count=$((count + 1))
			fi
			;;
		TITLE:*)
			[[ -n "$current_id" ]] && task_set "$current_id" "title" "$(printf '%s' "$line" | sed 's/^TITLE:[[:space:]]*//')"
			;;
		ROLE:*)
			[[ -n "$current_id" ]] && task_set "$current_id" "role" "$(printf '%s' "$line" | sed 's/^ROLE:[[:space:]]*//')"
			;;
		DEPS:*)
			local deps_val
			deps_val=$(printf '%s' "$line" | sed 's/^DEPS:[[:space:]]*//')
			if [[ "$deps_val" == "none" ]] || [[ -z "$deps_val" ]]; then
				deps_val=""
			fi
			[[ -n "$current_id" ]] && task_set "$current_id" "deps" "$deps_val"
			;;
		DESCRIPTION:*)
			[[ -n "$current_id" ]] && task_set "$current_id" "description" "$(printf '%s' "$line" | sed 's/^DESCRIPTION:[[:space:]]*//')"
			;;
		ACCEPTANCE:*)
			[[ -n "$current_id" ]] && task_set "$current_id" "acceptance" "$(printf '%s' "$line" | sed 's/^ACCEPTANCE:[[:space:]]*//')"
			;;
		esac
	done <"$plan_file"

	if ((count == 0)); then
		printf 'warning: no tasks parsed from plan output\n'
		printf 'raw output saved to: %s\n' "$plan_file"
		printf 'you can manually create tasks with: orchd task add <id>\n'
		return 1
	fi

	printf '\nparsed %d tasks:\n\n' "$count"
	_print_task_table
	printf '\nnext: orchd spawn --all  (or orchd spawn <task-id>)\n'
}

# --- Print task table ---
_print_task_table() {
	printf '%-20s %-30s %-8s %-10s %s\n' "ID" "TITLE" "ROLE" "STATUS" "DEPS"
	printf '%-20s %-30s %-8s %-10s %s\n' "---" "---" "---" "---" "---"

	local task_id
	while IFS= read -r task_id; do
		[[ -z "$task_id" ]] && continue
		local title role status deps
		title=$(task_get "$task_id" "title" "-")
		role=$(task_get "$task_id" "role" "-")
		status=$(task_get "$task_id" "status" "pending")
		deps=$(task_get "$task_id" "deps" "-")
		[[ -z "$deps" ]] && deps="-"
		# Truncate title if too long
		if ((${#title} > 28)); then
			title="${title:0:25}..."
		fi
		printf '%-20s %-30s %-8s %-10s %s\n' "$task_id" "$title" "$role" "$status" "$deps"
	done <<<"$(task_list_ids)"
}
