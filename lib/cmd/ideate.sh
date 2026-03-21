#!/usr/bin/env bash
# lib/cmd/ideate.sh - orchd ideate command
# AI-driven idea generation: asks the runner "what should we build next?"
# based on project brief, progress, lessons, and codebase structure.
#
# Returns:
#   0 — ideas were generated and pushed to the queue
#   1 — error (empty output, parse failure, runner failure)
#   2 — PROJECT_COMPLETE (all project goals met)

cmd_ideate() {
	case "${1:-}" in
	-h | --help)
		cat <<'EOF'
usage:
  orchd ideate                   Generate next ideas from project goals
  orchd ideate --dry-run         Show what would be suggested (no queue push)
  orchd ideate --runner <runner> Override runner for ideation
EOF
		return 0
		;;
	esac

	require_project

	local dry_run=false
	local runner_override=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dry-run)
			dry_run=true
			shift
			;;
		--runner)
			shift
			runner_override="${1:-}"
			[[ -n "$runner_override" ]] || die "usage: orchd ideate --runner <runner>"
			shift
			;;
		*)
			die "unknown option: $1 (try: orchd ideate --help)"
			;;
		esac
	done

	# Resolve runner
	local runner
	if [[ -n "$runner_override" ]]; then
		runner="$runner_override"
	else
		runner=$(detect_runner)
	fi
	if [[ "$runner" == "none" ]]; then
		die "no AI runner available. Install codex, claude, opencode, or aider."
	fi
	runner_validate "$runner"

	# Ensure memory bank exists (scaffold if needed)
	memory_ensure_scaffold

	# --- Gather context for the prompt ---
	local mem_dir="$PROJECT_ROOT/docs/memory"

	# 1. Project brief (full — this is the scope document, never truncate)
	local project_brief="(no project brief found)"
	if [[ -f "$mem_dir/projectbrief.md" ]]; then
		project_brief=$(cat "$mem_dir/projectbrief.md" 2>/dev/null || true)
	fi

	# 2. Progress
	local progress="(no progress data yet)"
	if [[ -f "$mem_dir/progress.md" ]]; then
		progress=$(cat "$mem_dir/progress.md" 2>/dev/null || true)
	fi

	# 3. Active context
	local active_context="(no active context)"
	if [[ -f "$mem_dir/activeContext.md" ]]; then
		active_context=$(cat "$mem_dir/activeContext.md" 2>/dev/null || true)
	fi

	# 4. Lessons (bounded)
	local lessons="(no lessons yet)"
	if [[ -d "$mem_dir/lessons" ]]; then
		local lesson_content=""
		local lf
		while IFS= read -r lf; do
			[[ -n "$lf" ]] || continue
			local lc
			lc=$(cat "$lf" 2>/dev/null || true)
			if [[ -n "$lc" ]]; then
				lesson_content+="$lc"$'\n\n'
			fi
			# Cap at ~4000 chars to leave room for other context
			if ((${#lesson_content} > 4000)); then
				lesson_content="${lesson_content:0:4000}"$'\n[TRUNCATED]'
				break
			fi
		done < <(ls -t "$mem_dir/lessons"/*.md 2>/dev/null || true)
		if [[ -n "$lesson_content" ]]; then
			lessons="$lesson_content"
		fi
	fi

	# 5. Completed ideas from queue (so AI doesn't repeat them)
	local completed_ideas="(none yet)"
	local qf
	qf=$(queue_file)
	if [[ -f "$qf" ]]; then
		local ci_list=""
		while IFS= read -r line; do
			case "$line" in
			'- [x] '*)
				# Strip status marker and timestamp prefix
				local idea_text="${line#- \[x\] }"
				# Remove ISO timestamp prefix if present
				idea_text=$(printf '%s' "$idea_text" | sed 's/^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T[0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}Z //')
				ci_list+="- $idea_text"$'\n'
				;;
			esac
		done <"$qf"
		if [[ -n "$ci_list" ]]; then
			completed_ideas="$ci_list"
		fi
	fi

	# 6. Codebase structure (bounded)
	local dir_lines
	dir_lines=$(config_get_int "orchestrator.plan_dir_lines" "80")
	local codebase_structure=""
	if [[ -d "$PROJECT_ROOT/src" ]] || [[ -d "$PROJECT_ROOT/lib" ]] || [[ -d "$PROJECT_ROOT/app" ]]; then
		codebase_structure=$(find "$PROJECT_ROOT" -maxdepth 3 \
			-not -path '*/.git/*' -not -path '*/.orchd/*' \
			-not -path '*/node_modules/*' -not -path '*/.worktrees/*' |
			awk -v max="$dir_lines" 'NR <= max { print }')
	else
		codebase_structure=$(find "$PROJECT_ROOT" -maxdepth 2 \
			-not -path '*/.git/*' -not -path '*/.orchd/*' |
			awk -v max="$dir_lines" 'NR <= max { print }')
	fi

	# --- Build prompt from template ---
	local template_file="$ORCHD_LIB_DIR/../templates/ideate.prompt"
	local prompt
	if [[ -f "$template_file" ]]; then
		prompt=$(cat "$template_file")
	else
		die "ideate template not found: $template_file"
	fi

	prompt=$(replace_token "$prompt" "{project_brief}" "$project_brief")
	prompt=$(replace_token "$prompt" "{progress}" "$progress")
	prompt=$(replace_token "$prompt" "{active_context}" "$active_context")
	prompt=$(replace_token "$prompt" "{lessons}" "$lessons")
	prompt=$(replace_token "$prompt" "{completed_ideas}" "$completed_ideas")
	prompt=$(replace_token "$prompt" "{codebase_structure}" "$codebase_structure")

	# Save prompt for debugging
	printf '%s\n' "$prompt" >"$ORCHD_DIR/last_ideate_prompt.txt"

	printf 'ideating: asking %s for next ideas...\n' "$runner"
	log_event "INFO" "ideate: invoking $runner"

	# --- Execute via runner (synchronous, same pattern as plan.sh) ---
	local ideate_output="$ORCHD_DIR/ideate_output.txt"
	local err_file="$ORCHD_DIR/ideate_stderr.log"

	case "$runner" in
	codex)
		local codex_bin
		codex_bin=$(config_get "codex_bin" "codex")
		local raw_jsonl="$ORCHD_DIR/ideate_raw.jsonl"
		"$codex_bin" exec "$prompt" -C "$PROJECT_ROOT" --json >"$raw_jsonl" 2>"$err_file" || {
			log_event "ERROR" "ideate: codex invocation failed"
			die "codex ideation failed. See $err_file"
		}
		_ideate_extract_text_from_jsonl <"$raw_jsonl" >"$ideate_output" || {
			die "failed to extract ideate text from codex JSONL. See $raw_jsonl"
		}
		;;
	claude)
		local claude_bin
		claude_bin=$(config_get "claude_bin" "claude")
		"$claude_bin" -p "$prompt" --output-format text >"$ideate_output" 2>"$err_file" || {
			log_event "ERROR" "ideate: claude invocation failed"
			die "claude ideation failed. See $err_file"
		}
		;;
	opencode)
		local opencode_bin
		opencode_bin=$(config_get "opencode_bin" "opencode")
		"$opencode_bin" -p "$prompt" >"$ideate_output" 2>"$err_file" || {
			log_event "ERROR" "ideate: opencode invocation failed"
			die "opencode ideation failed. See $err_file"
		}
		;;
	aider)
		aider --message "$prompt" --yes --no-git >"$ideate_output" 2>"$err_file" || {
			log_event "ERROR" "ideate: aider invocation failed"
			die "aider ideation failed. See $err_file"
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
		custom_cmd=$(replace_token "$custom_cmd" "{task_id}" "$(printf '%q' "ideate")")
		custom_cmd=$(replace_token "$custom_cmd" "{log_file}" "$(printf '%q' "$ideate_output")")
		eval "$custom_cmd" >"$ideate_output" 2>/dev/null || {
			log_event "ERROR" "ideate: custom runner failed"
			die "custom ideation failed"
		}
		;;
	*)
		die "unsupported runner for ideation: $runner"
		;;
	esac

	if [[ ! -s "$ideate_output" ]]; then
		printf 'error: ideation output is empty\n' >&2
		printf '  prompt:  %s\n' "$ORCHD_DIR/last_ideate_prompt.txt" >&2
		printf '  output:  %s\n' "$ideate_output" >&2
		if [[ -f "$err_file" ]]; then
			printf '  stderr:  %s\n' "$err_file" >&2
		fi
		log_event "ERROR" "ideate: empty output"
		return 1
	fi

	# --- Parse the output ---
	_ideate_parse_output "$ideate_output" "$dry_run"
	return $?
}

# Parse ideate output: extract IDEA/REASON lines or PROJECT_COMPLETE.
# Args: $1 = output file path, $2 = dry_run (true/false)
# Returns: 0 = ideas pushed, 1 = parse error, 2 = PROJECT_COMPLETE
_ideate_parse_output() {
	local output_file=$1
	local dry_run=${2:-false}

	local max_ideas
	max_ideas=$(config_get_int "ideate.max_ideas" "5")

	local idea_count=0
	local current_idea=""
	local current_reason=""
	local project_complete=false
	local complete_reason=""

	while IFS= read -r line || [[ -n "$line" ]]; do
		# Strip leading/trailing whitespace
		line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

		# Skip empty lines after stripping
		[[ -z "$line" ]] && continue

		# Check for PROJECT_COMPLETE
		if [[ "$line" == "PROJECT_COMPLETE" ]]; then
			project_complete=true
			continue
		fi

		# If we already saw PROJECT_COMPLETE, capture the reason
		if $project_complete; then
			if [[ "$line" =~ ^REASON:[[:space:]]*(.+)$ ]]; then
				complete_reason="${BASH_REMATCH[1]}"
			fi
			continue
		fi

		# Parse IDEA lines
		if [[ "$line" =~ ^IDEA:[[:space:]]*(.+)$ ]]; then
			# Flush previous idea if any
			if [[ -n "$current_idea" ]] && ((idea_count < max_ideas)); then
				_ideate_push_idea "$current_idea" "$current_reason" "$dry_run"
				idea_count=$((idea_count + 1))
			fi
			current_idea="${BASH_REMATCH[1]}"
			current_reason=""
			continue
		fi

		# Parse REASON lines
		if [[ "$line" =~ ^REASON:[[:space:]]*(.+)$ ]]; then
			current_reason="${BASH_REMATCH[1]}"
			continue
		fi
	done <"$output_file"

	# Flush last idea
	if [[ -n "$current_idea" ]] && ((idea_count < max_ideas)); then
		_ideate_push_idea "$current_idea" "$current_reason" "$dry_run"
		idea_count=$((idea_count + 1))
	fi

	# Handle PROJECT_COMPLETE
	if $project_complete; then
		printf '\n'
		printf '┌─────────────────────────────────────┐\n'
		printf '│         PROJECT COMPLETE             │\n'
		printf '├─────────────────────────────────────┤\n'
		printf '└─────────────────────────────────────┘\n'
		if [[ -n "$complete_reason" ]]; then
			printf 'reason: %s\n' "$complete_reason"
		fi
		log_event "INFO" "ideate: PROJECT_COMPLETE — ${complete_reason:-no reason given}"
		return 2
	fi

	if ((idea_count == 0)); then
		printf 'warning: no ideas parsed from output\n' >&2
		printf '  check: %s\n' "$output_file" >&2
		log_event "WARN" "ideate: no ideas parsed from output"
		return 1
	fi

	printf '\nideate: %d idea(s) %s\n' "$idea_count" \
		"$($dry_run && printf 'found (dry-run, not queued)' || printf 'queued')"
	log_event "INFO" "ideate: $idea_count ideas generated"
	return 0
}

# Push a single idea to the queue (or print in dry-run mode).
_ideate_push_idea() {
	local idea=$1
	local reason=$2
	local dry_run=$3

	if $dry_run; then
		printf '  [DRY] %s\n' "$idea"
		if [[ -n "$reason" ]]; then
			printf '        reason: %s\n' "$reason"
		fi
	else
		queue_push "$idea"
		printf '  [+] %s\n' "$idea"
		if [[ -n "$reason" ]]; then
			log_event "INFO" "ideate: queued idea — $idea (reason: $reason)"
		fi
	fi
}

# Extract text from codex JSONL output (same as plan.sh helper).
_ideate_extract_text_from_jsonl() {
	if command -v jq >/dev/null 2>&1; then
		jq -r 'select(.type=="item.completed" and (.item.type=="agent_message" or .item.type=="assistant_message")) | .item.text // empty' 2>/dev/null
	else
		sed -n 's/.*"text"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null || cat
	fi
}
