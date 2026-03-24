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
  orchd ideate --completion-policy <policy>

policies:
  expand_after_scope (default)   Keep ideating next-phase work after scope completion
  strict_scope                   Return PROJECT_COMPLETE once brief scope is fully done
EOF
		return 0
		;;
	esac

	require_project

	local dry_run=false
	local runner_override=""
	local completion_policy_override=""

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
		--completion-policy)
			shift
			completion_policy_override="${1:-}"
			[[ -n "$completion_policy_override" ]] || die "usage: orchd ideate --completion-policy <policy>"
			shift
			;;
		--strict-scope)
			completion_policy_override="strict_scope"
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
		runner=$(swarm_select_runner_for_role "planner" "$(detect_runner)")
	fi
	if [[ "$runner" == "none" ]]; then
		die "no AI runner available. Install codex, claude, opencode, or aider."
	fi
	runner_validate "$runner"

	local completion_policy
	if [[ -n "$completion_policy_override" ]]; then
		completion_policy="$completion_policy_override"
	else
		completion_policy=$(config_get "ideate.completion_policy" "expand_after_scope")
	fi
	completion_policy=$(_ideate_normalize_completion_policy "$completion_policy") || {
		die "unsupported ideate completion policy: $completion_policy"
	}

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
	prompt=$(replace_token "$prompt" "{completion_policy_name}" "$completion_policy")
	prompt=$(replace_token "$prompt" "{completion_policy_instructions}" "$(_ideate_completion_policy_instructions "$completion_policy")")

	# Save prompt for debugging
	printf '%s\n' "$prompt" >"$ORCHD_DIR/last_ideate_prompt.txt"

	printf 'ideating: asking %s for next ideas...\n' "$runner"
	log_event "INFO" "ideate: invoking $runner"

	# --- Execute via runner (synchronous, same pattern as plan.sh) ---
	local ideate_output="$ORCHD_DIR/ideate_output.txt"
	local err_file="$ORCHD_DIR/ideate_stderr.log"
	_ideate_execute_prompt "$runner" "$prompt" "$ideate_output" "$err_file" "primary"

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
	local allow_project_complete=true
	if [[ "$completion_policy" != "strict_scope" ]]; then
		allow_project_complete=false
	fi

	local parse_rc=0
	if (
		set +e
		_ideate_parse_output "$ideate_output" "$dry_run" "$allow_project_complete" "scope"
	); then
		parse_rc=0
	else
		parse_rc=$?
	fi
	if ((parse_rc == 2)) && [[ "$completion_policy" != "strict_scope" ]]; then
		local follow_on_prompt follow_on_output follow_on_err complete_reason
		complete_reason=$(_ideate_extract_completion_reason "$ideate_output")
		follow_on_prompt=$(_ideate_build_follow_on_prompt "$prompt" "$complete_reason")
		follow_on_output="$ORCHD_DIR/ideate_follow_on_output.txt"
		follow_on_err="$ORCHD_DIR/ideate_follow_on_stderr.log"
		printf '%s\n' "$follow_on_prompt" >"$ORCHD_DIR/last_ideate_follow_on_prompt.txt"
		printf 'ideating: scoped goals are complete; asking %s for next-phase ideas...\n' "$runner"
		log_event "INFO" "ideate: PROJECT_COMPLETE deferred; requesting follow-on ideas"
		_ideate_execute_prompt "$runner" "$follow_on_prompt" "$follow_on_output" "$follow_on_err" "follow-on"
		if [[ ! -s "$follow_on_output" ]]; then
			printf 'error: follow-on ideation output is empty\n' >&2
			printf '  prompt:  %s\n' "$ORCHD_DIR/last_ideate_follow_on_prompt.txt" >&2
			printf '  output:  %s\n' "$follow_on_output" >&2
			if [[ -f "$follow_on_err" ]]; then
				printf '  stderr:  %s\n' "$follow_on_err" >&2
			fi
			log_event "ERROR" "ideate: empty follow-on output"
			return 1
		fi
		local follow_on_rc=0
		if (
			set +e
			_ideate_parse_output "$follow_on_output" "$dry_run" true "follow_on"
		); then
			follow_on_rc=0
		else
			follow_on_rc=$?
		fi
		return $follow_on_rc
	fi

	return $parse_rc
}

_finish_state_dir() {
	printf '%s/finish\n' "$ORCHD_DIR"
}

finish_record_state() {
	local state=$1
	local reason=${2:-}
	mkdir -p "$(_finish_state_dir)"
	printf '%s\n' "$state" >"$(_finish_state_dir)/state"
	printf '%s\n' "$reason" >"$(_finish_state_dir)/reason"
	printf '%s\n' "$(now_iso)" >"$(_finish_state_dir)/updated_at"
}

_ideate_normalize_completion_policy() {
	local policy
	policy=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
	case "$policy" in
	strict | strict_scope | scope_only)
		printf 'strict_scope\n'
		return 0
		;;
	expand | expand_after_scope | continue | continue_after_scope)
		printf 'expand_after_scope\n'
		return 0
		;;
	esac
	return 1
}

_ideate_completion_policy_instructions() {
	local policy=$1
	case "$policy" in
	strict_scope)
		cat <<'EOF'
- ONLY suggest work that is IN SCOPE per the project brief
- If ALL goals and scope items in the project brief are fully met, output ONLY: PROJECT_COMPLETE
EOF
		;;
	expand_after_scope)
		cat <<'EOF'
- First exhaust all concrete work that is directly in scope per the project brief
- If the original brief is fully satisfied, pivot to the best next-phase work that remains grounded in the current product, recent progress, and codebase
- In that post-scope phase, favor high-leverage follow-on work such as release hardening, reliability, observability, security, performance, monetization iteration, retention, UX polish, experimentation, admin/support tooling, and post-launch readiness
- Keep post-scope ideas concrete, professional, and implementation-ready; do not drift into vague process work
- Prefer generating strong follow-on ideas over declaring PROJECT_COMPLETE; only use PROJECT_COMPLETE if there is truly no credible next step worth doing
EOF
		;;
	*)
		return 1
		;;
	esac
}

_ideate_execute_prompt() {
	local runner=$1
	local prompt=$2
	local output_file=$3
	local err_file=$4
	local phase=${5:-primary}

	case "$runner" in
	codex)
		local codex_bin raw_jsonl
		codex_bin=$(config_get "codex_bin" "codex")
		raw_jsonl="$ORCHD_DIR/ideate_${phase}_raw.jsonl"
		"$codex_bin" exec "$prompt" -C "$PROJECT_ROOT" --json >"$raw_jsonl" 2>"$err_file" || {
			log_event "ERROR" "ideate: codex invocation failed ($phase)"
			die "codex ideation failed. See $err_file"
		}
		_ideate_extract_text_from_jsonl <"$raw_jsonl" >"$output_file" || {
			die "failed to extract ideate text from codex JSONL. See $raw_jsonl"
		}
		;;
	claude)
		local claude_bin
		claude_bin=$(config_get "claude_bin" "claude")
		"$claude_bin" -p "$prompt" --output-format text >"$output_file" 2>"$err_file" || {
			log_event "ERROR" "ideate: claude invocation failed ($phase)"
			die "claude ideation failed. See $err_file"
		}
		;;
	opencode)
		local opencode_bin
		opencode_bin=$(config_get "opencode_bin" "opencode")
		"$opencode_bin" -p "$prompt" >"$output_file" 2>"$err_file" || {
			log_event "ERROR" "ideate: opencode invocation failed ($phase)"
			die "opencode ideation failed. See $err_file"
		}
		;;
	aider)
		aider --message "$prompt" --yes --no-git >"$output_file" 2>"$err_file" || {
			log_event "ERROR" "ideate: aider invocation failed ($phase)"
			die "aider ideation failed. See $err_file"
		}
		;;
	custom)
		local custom_cmd
		custom_cmd=$(config_get_custom_runner_cmd)
		if [[ -z "$custom_cmd" ]]; then
			die "custom runner requires 'custom_runner_cmd' in .orchd.toml"
		fi
		custom_cmd=$(replace_token "$custom_cmd" "{prompt}" "$(printf '%q' "$prompt")")
		custom_cmd=$(replace_token "$custom_cmd" "{worktree}" "$(printf '%q' "$PROJECT_ROOT")")
		custom_cmd=$(replace_token "$custom_cmd" "{task_id}" "$(printf '%q' "ideate")")
		custom_cmd=$(replace_token "$custom_cmd" "{log_file}" "$(printf '%q' "$output_file")")
		eval "$custom_cmd" >"$output_file" 2>/dev/null || {
			log_event "ERROR" "ideate: custom runner failed ($phase)"
			die "custom ideation failed"
		}
		;;
	*)
		die "unsupported runner for ideation: $runner"
		;;
	esac
}

_ideate_extract_completion_reason() {
	local output_file=$1
	local line
	while IFS= read -r line || [[ -n "$line" ]]; do
		line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
		if [[ "$line" =~ ^REASON:[[:space:]]*(.+)$ ]]; then
			printf '%s\n' "${BASH_REMATCH[1]}"
			return 0
		fi
	done <"$output_file"
	return 1
}

_ideate_build_follow_on_prompt() {
	local base_prompt=$1
	local completion_reason=${2:-the original brief appears complete}
	cat <<EOF
$base_prompt

## Follow-On Ideation Override

The previous ideation pass concluded that the original project brief is complete.
Completion reason: $completion_reason

For this pass:
- Do NOT output PROJECT_COMPLETE
- Generate 1-5 concrete next-phase ideas with IDEA:/REASON: lines only
- Favor creative but professional follow-on work that materially improves the product after the original scope: release hardening, reliability, observability, security, monetization iteration, retention, UX polish, experimentation, growth loops, support/admin tooling, and post-launch readiness
- Stay grounded in the actual codebase and recent delivery history
- Keep ideas implementation-ready and non-redundant
EOF
}

# Parse ideate output: extract IDEA/REASON lines or PROJECT_COMPLETE.
# Args: $1 = output file path, $2 = dry_run (true/false), $3 = allow_project_complete (true/false), $4 = phase name
# Returns: 0 = ideas pushed, 1 = parse error, 2 = PROJECT_COMPLETE
_ideate_parse_output() {
	local output_file=$1
	local dry_run=${2:-false}
	local allow_project_complete=${3:-true}
	local phase_name=${4:-scope}

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
		if [[ "$allow_project_complete" != "true" ]]; then
			finish_record_state "scope_complete" "${complete_reason:-scope appears complete}"
			log_event "INFO" "ideate: PROJECT_COMPLETE candidate deferred for follow-on ideation — ${complete_reason:-no reason given}"
			return 2
		fi
		printf '\n'
		printf '┌─────────────────────────────────────┐\n'
		printf '│         PROJECT COMPLETE             │\n'
		printf '├─────────────────────────────────────┤\n'
		printf '└─────────────────────────────────────┘\n'
		if [[ -n "$complete_reason" ]]; then
			printf 'reason: %s\n' "$complete_reason"
		fi
		finish_record_state "project_complete" "${complete_reason:-all scoped work appears complete}"
		log_event "INFO" "ideate: PROJECT_COMPLETE — ${complete_reason:-no reason given}"
		return 2
	fi

	if ((idea_count == 0)); then
		finish_record_state "stalled" "ideate produced no parseable ideas"
		printf 'warning: no ideas parsed from output\n' >&2
		printf '  check: %s\n' "$output_file" >&2
		log_event "WARN" "ideate: no ideas parsed from output"
		return 1
	fi

	printf '\nideate: %d idea(s) %s\n' "$idea_count" \
		"$($dry_run && printf 'found (dry-run, not queued)' || printf 'queued')"
	if [[ "$phase_name" == "follow_on" ]]; then
		finish_record_state "next_phase_available" "follow-on work was generated after scope completion"
	else
		finish_record_state "backlog_available" "implementation-ready ideas were generated"
	fi
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
