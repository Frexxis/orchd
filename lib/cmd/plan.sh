#!/usr/bin/env bash
# lib/cmd/plan.sh - orchd plan command
# Uses AI to generate a task DAG from a project description

cmd_plan() {
	# Modes:
	#   orchd plan "<description>"     (generate via AI)
	#   orchd plan --runner <runner> "<description>"
	#   orchd plan --file <path>       (load an existing plan output)
	#   orchd plan --stdin             (read plan output from stdin)
	local runner_override=""
	if [[ "${1:-}" == "--runner" ]]; then
		runner_override="${2:-}"
		[[ -n "$runner_override" ]] || die "usage: orchd plan --runner <runner> \"<project description>\""
		shift 2
	fi

	local mode="${1:-}"
	if [[ "$mode" == "-h" || "$mode" == "--help" ]]; then
		cat <<'EOF'
usage:
  orchd plan [--runner <runner>] "<project description>"
  orchd plan --file <path>
  orchd plan --stdin

notes:
  - --runner overrides the configured/auto-detected runner for planning only
  - plan output must follow the TASK/TITLE/ROLE/DEPS/DESCRIPTION/ACCEPTANCE format
  - optional per-task overrides: LINT_CMD, TEST_CMD, BUILD_CMD
EOF
		return 0
	fi
	if [[ "$mode" == "--file" ]]; then
		local plan_file="${2:-}"
		[[ -n "$plan_file" ]] || die "usage: orchd plan --file <path>"
		require_project
		[[ -f "$plan_file" ]] || die "plan file not found: $plan_file"
		cp "$plan_file" "$ORCHD_DIR/plan_output.txt"
		_parse_plan_output "$ORCHD_DIR/plan_output.txt" || die "plan parsed 0 tasks from file: $plan_file"
		return 0
	fi
	if [[ "$mode" == "--stdin" ]]; then
		require_project
		cat >"$ORCHD_DIR/plan_output.txt"
		_parse_plan_output "$ORCHD_DIR/plan_output.txt" || die "plan parsed 0 tasks from stdin"
		return 0
	fi

	local description="$*"
	[[ -n "$description" ]] || die "usage: orchd plan [--runner <runner>] \"<project description>\" | orchd plan --file <path> | orchd plan --stdin"

	require_project

	local runner
	if [[ -n "$runner_override" ]]; then
		runner="$runner_override"
	else
		runner=$(detect_runner)
	fi
	runner_validate "$runner"

	# Gather codebase context (bounded to reduce context-limit failures)
	local dir_lines stack_lines doc_lines docs_lines docs_max_files max_chars
	dir_lines=$(config_get "orchestrator.plan_dir_lines" "80")
	stack_lines=$(config_get "orchestrator.plan_stack_lines" "30")
	doc_lines=$(config_get "orchestrator.plan_doc_lines" "120")
	docs_lines=$(config_get "orchestrator.plan_docs_lines" "60")
	docs_max_files=$(config_get "orchestrator.plan_docs_max_files" "5")
	max_chars=$(config_get "orchestrator.plan_max_context_chars" "40000")

	local context=""
	if [[ -d "$PROJECT_ROOT/src" ]] || [[ -d "$PROJECT_ROOT/lib" ]] || [[ -d "$PROJECT_ROOT/app" ]]; then
		context="Directory structure:\n$(find "$PROJECT_ROOT" -maxdepth 3 -not -path '*/.git/*' -not -path '*/.orchd/*' -not -path '*/node_modules/*' -not -path '*/.worktrees/*' | head -n "$dir_lines")"
	else
		context="Directory structure:\n$(find "$PROJECT_ROOT" -maxdepth 2 -not -path '*/.git/*' -not -path '*/.orchd/*' | head -n "$dir_lines")"
	fi

	# Check for package.json, Cargo.toml, etc. for stack detection
	local stack_files=""
	for f in package.json Cargo.toml go.mod pyproject.toml requirements.txt pom.xml build.gradle Makefile; do
		if [[ -f "$PROJECT_ROOT/$f" ]]; then
			stack_files="$stack_files\n--- $f ---\n$(head -n "$stack_lines" "$PROJECT_ROOT/$f")"
		fi
	done
	if [[ -n "$stack_files" ]]; then
		context="$context\n\nDetected project files:$stack_files"
	fi

	# Scan for project documentation (requirements, phases, roadmaps, etc.)
	local doc_content=""
	for f in PHASES.md PRD.md ROADMAP.md TODO.md BACKLOG.md ARCHITECTURE.md DESIGN.md SPEC.md; do
		if [[ -f "$PROJECT_ROOT/$f" ]]; then
			doc_content="$doc_content\n--- $f ---\n$(head -n "$doc_lines" "$PROJECT_ROOT/$f")"
		fi
	done
	# Also check docs/ directory for planning files
	if [[ -d "$PROJECT_ROOT/docs" ]]; then
		local df_count=0
		while IFS= read -r -d '' df; do
			local fname
			fname=$(basename "$df")
			doc_content="$doc_content\n--- docs/$fname ---\n$(head -n "$docs_lines" "$df")"
			df_count=$((df_count + 1))
			if [[ "$df_count" -ge "$docs_max_files" ]]; then
				break
			fi
		done < <(find "$PROJECT_ROOT/docs" -maxdepth 2 -name '*.md' -print0 2>/dev/null)
	fi
	if [[ -n "$doc_content" ]]; then
		context="$context\n\nProject documentation:$doc_content"
	fi

	# Truncate context if needed
	if [[ -n "$max_chars" ]] && [[ "$max_chars" =~ ^[0-9]+$ ]]; then
		if ((${#context} > max_chars)); then
			context="${context:0:max_chars}"
			context+=$'\n\n[TRUNCATED: context capped to orchestrator.plan_max_context_chars]'
		fi
	fi

	# Build the planning prompt from template
	local template_file="$ORCHD_LIB_DIR/../templates/plan.prompt"
	if [[ ! -f "$template_file" ]]; then
		die "plan template not found: $template_file"
	fi

	local prompt
	prompt=$(cat "$template_file")
	prompt=$(replace_token "$prompt" "{project_description}" "$description")
	prompt=$(replace_token "$prompt" "{codebase_context}" "$context")

	printf 'generating task plan with %s...\n' "$runner"

	# Save prompt for debugging
	printf '%s\n' "$prompt" >"$ORCHD_DIR/last_plan_prompt.txt"

	# Execute via runner to get plan output
	local plan_output="$ORCHD_DIR/plan_output.txt"

	case "$runner" in
	codex)
		local codex_bin
		codex_bin=$(config_get "codex_bin" "codex")
		local raw_jsonl="$ORCHD_DIR/plan_raw.jsonl"
		local err_file="$ORCHD_DIR/plan_stderr.log"
		"$codex_bin" exec "$prompt" -C "$PROJECT_ROOT" --json >"$raw_jsonl" 2>"$err_file" || {
			die "codex plan generation failed. See $err_file and $ORCHD_DIR/last_plan_prompt.txt"
		}
		_extract_text_from_jsonl <"$raw_jsonl" >"$plan_output" || {
			die "failed to extract plan text from codex JSONL. See $raw_jsonl"
		}
		;;
	claude)
		local claude_bin
		claude_bin=$(config_get "claude_bin" "claude")
		"$claude_bin" -p "$prompt" --output-format text >"$plan_output" 2>"$ORCHD_DIR/plan_stderr.log" || {
			die "claude plan generation failed. See $ORCHD_DIR/plan_stderr.log"
		}
		;;
	opencode)
		opencode -p "$prompt" >"$plan_output" 2>"$ORCHD_DIR/plan_stderr.log" || {
			die "opencode plan generation failed. See $ORCHD_DIR/plan_stderr.log"
		}
		;;
	aider)
		aider --message "$prompt" --yes --no-git >"$plan_output" 2>"$ORCHD_DIR/plan_stderr.log" || {
			die "aider plan generation failed. See $ORCHD_DIR/plan_stderr.log"
		}
		;;
	custom)
		local custom_cmd
		custom_cmd=$(config_get "custom_runner_cmd" "")
		if [[ -z "$custom_cmd" ]]; then
			die "custom runner requires 'custom_runner_cmd' in .orchd.toml"
		fi
		custom_cmd=$(replace_token "$custom_cmd" "{prompt}" "$(printf '%q' "$prompt")")
		custom_cmd=$(replace_token "$custom_cmd" "{worktree}" "$(printf '%q' "$PROJECT_ROOT")")
		custom_cmd=$(replace_token "$custom_cmd" "{task_id}" "$(printf '%q' "plan")")
		custom_cmd=$(replace_token "$custom_cmd" "{log_file}" "$(printf '%q' "$plan_output")")
		eval "$custom_cmd" >"$plan_output" 2>/dev/null || {
			die "custom plan generation failed"
		}
		;;
	*)
		die "unsupported runner for planning: $runner"
		;;
	esac

	if [[ ! -s "$plan_output" ]]; then
		printf 'error: plan output is empty\n' >&2
		printf '  prompt:  %s\n' "$ORCHD_DIR/last_plan_prompt.txt" >&2
		printf '  output:  %s\n' "$plan_output" >&2
		if [[ -f "$ORCHD_DIR/plan_stderr.log" ]]; then
			printf '  stderr:  %s\n' "$ORCHD_DIR/plan_stderr.log" >&2
			printf '\nlast stderr lines:\n' >&2
			tail -n 20 "$ORCHD_DIR/plan_stderr.log" >&2 || true
		fi
		die "plan generation produced empty output"
	fi

	# Parse the plan output into task state files
	_parse_plan_output "$plan_output" || die "plan parsed 0 tasks. Check $plan_output and templates/plan.prompt"
}

# --- Extract text content from JSONL (codex output) ---
_extract_text_from_jsonl() {
	if command -v jq >/dev/null 2>&1; then
		jq -r 'select(.type=="item.completed" and (.item.type=="agent_message" or .item.type=="assistant_message")) | .item.text // empty' 2>/dev/null
	else
		# Fallback: portable sed (no grep -oP, which is unavailable on macOS)
		sed -n 's/.*"text"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null || cat
	fi
}

# --- Parse TASK blocks from plan output ---
# Supports multi-line DESCRIPTION and ACCEPTANCE fields.
# A new keyword line or EOF flushes the accumulated multi-line value.
_parse_plan_output() {
	local plan_file=$1
	local current_id=""
	local current_field=""
	local current_value=""
	local count=0
	ORCHD_PLAN_TASK_COUNT=0

	# Clear existing tasks
	if [[ -d "$TASKS_DIR" ]] && [[ -n "$(ls -A "$TASKS_DIR" 2>/dev/null)" ]]; then
		printf 'warning: clearing existing task plan\n'
		rm -rf "${TASKS_DIR:?}"/*
	fi

	while IFS= read -r line || [[ -n "$line" ]]; do
		# Detect keyword lines
		local keyword=""
		case "$line" in
		TASK:*) keyword="TASK" ;;
		TITLE:*) keyword="TITLE" ;;
		ROLE:*) keyword="ROLE" ;;
		DEPS:*) keyword="DEPS" ;;
		DESCRIPTION:*) keyword="DESCRIPTION" ;;
		ACCEPTANCE:*) keyword="ACCEPTANCE" ;;
		LINT_CMD:*) keyword="LINT_CMD" ;;
		TEST_CMD:*) keyword="TEST_CMD" ;;
		BUILD_CMD:*) keyword="BUILD_CMD" ;;
		esac

		if [[ -n "$keyword" ]]; then
			# Flush previous multi-line field before processing new keyword
			if [[ -n "$current_id" ]] && [[ -n "$current_field" ]]; then
				task_set "$current_id" "$current_field" "$current_value"
			fi
			current_field=""
			current_value=""

			local val
			val=$(printf '%s' "$line" | sed "s/^${keyword}:[[:space:]]*//")

			case "$keyword" in
			TASK)
				current_id=$(printf '%s' "$val" | tr -d '[:space:]')
				if [[ -n "$current_id" ]]; then
					mkdir -p "$TASKS_DIR/$current_id"
					task_set "$current_id" "status" "pending"
					count=$((count + 1))
				fi
				;;
			TITLE)
				[[ -n "$current_id" ]] && task_set "$current_id" "title" "$val"
				;;
			ROLE)
				[[ -n "$current_id" ]] && task_set "$current_id" "role" "$val"
				;;
			DEPS)
				if [[ "$val" == "none" ]] || [[ -z "$val" ]]; then
					val=""
				fi
				[[ -n "$current_id" ]] && task_set "$current_id" "deps" "$val"
				;;
			DESCRIPTION)
				current_field="description"
				current_value="$val"
				;;
			ACCEPTANCE)
				current_field="acceptance"
				current_value="$val"
				;;
			LINT_CMD)
				if [[ "$val" == "none" ]] || [[ "$val" == "auto" ]] || [[ -z "$val" ]]; then
					val=""
				fi
				[[ -n "$current_id" ]] && task_set "$current_id" "lint_cmd" "$val"
				;;
			TEST_CMD)
				if [[ "$val" == "none" ]] || [[ "$val" == "auto" ]] || [[ -z "$val" ]]; then
					val=""
				fi
				[[ -n "$current_id" ]] && task_set "$current_id" "test_cmd" "$val"
				;;
			BUILD_CMD)
				if [[ "$val" == "none" ]] || [[ "$val" == "auto" ]] || [[ -z "$val" ]]; then
					val=""
				fi
				[[ -n "$current_id" ]] && task_set "$current_id" "build_cmd" "$val"
				;;
			esac
		else
			# Non-keyword line: append to active multi-line field (preserve blank lines)
			if [[ -n "$current_field" ]]; then
				if [[ -n "$current_value" ]]; then
					current_value+=$'\n'"$line"
				else
					current_value="$line"
					if [[ -z "$line" ]]; then
						current_value=$'\n'
					fi
				fi
			fi
		fi
	done <"$plan_file"

	# Flush any remaining multi-line field at EOF
	if [[ -n "$current_id" ]] && [[ -n "$current_field" ]]; then
		task_set "$current_id" "$current_field" "$current_value"
	fi

	if ((count == 0)); then
		ORCHD_PLAN_TASK_COUNT=0
		printf 'warning: no tasks parsed from plan output\n'
		printf 'raw output saved to: %s\n' "$plan_file"
		printf 'review templates/plan.prompt or adjust parser format and retry\n'
		return 1
	fi

	ORCHD_PLAN_TASK_COUNT="$count"

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
