#!/usr/bin/env bash
# lib/cmd/review.sh - orchd review command
# Runs a review-only agent session against repo changes

_review_collect_worktree_context() {
	local worktree=$1
	local base_branch=$2
	local context untracked_file
	context="git status -sb (${worktree}):\n$(git -C "$worktree" status -sb 2>/dev/null || true)"
	context+=$'\n\n'
	context+="git diff ${base_branch}...HEAD (${worktree}):\n$(git -C "$worktree" diff "${base_branch}"...HEAD 2>/dev/null || true)"
	context+=$'\n\n'
	context+="git diff --cached (${worktree}):\n$(git -C "$worktree" diff --cached 2>/dev/null || true)"
	context+=$'\n\n'
	context+="git diff (unstaged) (${worktree}):\n$(git -C "$worktree" diff 2>/dev/null || true)"
	while IFS= read -r -d '' untracked_file; do
		context+=$'\n\n'
		context+="git diff --no-index -- /dev/null ${untracked_file} (${worktree}):\n$(git -C "$worktree" diff --no-index -- /dev/null "$untracked_file" 2>/dev/null || true)"
	done < <(git -C "$worktree" ls-files --others --exclude-standard -z 2>/dev/null || true)
	printf '%s' "$context"
}

_review_template_file() {
	local reviewer_template="$ORCHD_LIB_DIR/../templates/reviewer.prompt"
	local legacy_template="$ORCHD_LIB_DIR/../templates/review.prompt"
	if [[ -f "$reviewer_template" ]]; then
		printf '%s\n' "$reviewer_template"
		return 0
	fi
	printf '%s\n' "$legacy_template"
}

_review_run_prompt_to_file() {
	local runner=$1
	local prompt=$2
	local out_file=$3
	local runner_worktree=$4
	local runner_task_id=$5

	case "$runner" in
	codex)
		local codex_bin
		codex_bin=$(config_get "codex_bin" "codex")
		"$codex_bin" exec "$prompt" -C "$runner_worktree" --json 2>/dev/null |
			_extract_text_from_jsonl >"$out_file" || {
			die "codex review failed"
		}
		;;
	claude)
		local claude_bin
		claude_bin=$(config_get "claude_bin" "claude")
		(cd "$runner_worktree" && "$claude_bin" -p "$prompt" --output-format text 2>/dev/null >"$out_file") || {
			die "claude review failed"
		}
		;;
	opencode)
		local opencode_bin
		opencode_bin=$(config_get "opencode_bin" "opencode")
		(cd "$runner_worktree" && "$opencode_bin" -p "$prompt" 2>/dev/null >"$out_file") || {
			die "opencode review failed"
		}
		;;
	aider)
		(cd "$runner_worktree" && aider --message "$prompt" --yes --no-git 2>/dev/null >"$out_file") || {
			die "aider review failed"
		}
		;;
	custom)
		local custom_cmd
		custom_cmd=$(config_get_custom_runner_cmd)
		if [[ -z "$custom_cmd" ]]; then
			die "custom runner requires 'custom_runner_cmd' in .orchd.toml"
		fi
		custom_cmd=$(replace_token "$custom_cmd" "{prompt}" "$(printf '%q' "$prompt")")
		custom_cmd=$(replace_token "$custom_cmd" "{worktree}" "$(printf '%q' "$runner_worktree")")
		custom_cmd=$(replace_token "$custom_cmd" "{task_id}" "$(printf '%q' "$runner_task_id")")
		custom_cmd=$(replace_token "$custom_cmd" "{log_file}" "$(printf '%q' "$out_file")")
		eval "$custom_cmd" >"$out_file" 2>/dev/null || {
			die "custom review failed"
		}
		;;
	*)
		die "unsupported runner for review: $runner"
		;;
	esac
}

_review_run() {
	local target=${1:-}
	local task_id=${2:-}
	require_project

	local runner
	runner=$(swarm_select_runner_for_role "reviewer" "$(detect_runner)")
	runner_validate "$runner"

	local template_file
	template_file=$(_review_template_file)
	if [[ ! -f "$template_file" ]]; then
		die "review template not found: $template_file"
	fi

	local review_target="working tree"
	local context=""
	local runner_worktree="$PROJECT_ROOT"
	local runner_task_id="review"
	local out_file="$ORCHD_DIR/review_output.txt"
	if [[ -n "$task_id" ]]; then
		task_exists "$task_id" || die "task not found: $task_id"
		local branch base_branch worktree
		branch=$(task_get "$task_id" "branch" "agent-${task_id}")
		base_branch=$(config_get "base_branch" "main")
		worktree=$(task_get "$task_id" "worktree" "")
		review_target="task ${task_id} (${branch})"
		runner_task_id="$task_id"
		if [[ -n "$worktree" && -d "$worktree" ]]; then
			runner_worktree="$worktree"
			context=$(_review_collect_worktree_context "$worktree" "$base_branch")
		else
			context="git diff ${base_branch}...${branch}:\n$(git -C "$PROJECT_ROOT" diff "${base_branch}"..."${branch}" 2>/dev/null || true)"
		fi
		out_file="$(task_dir "$task_id")/review_output.txt"
	elif [[ -n "$target" ]]; then
		review_target="$target"
		if git -C "$PROJECT_ROOT" rev-parse --verify "$target^{commit}" >/dev/null 2>&1; then
			context="git show $target:\n$(git -C "$PROJECT_ROOT" show "$target")"
		else
			context="git diff $target...HEAD:\n$(git -C "$PROJECT_ROOT" diff "$target"...HEAD)"
		fi
	else
		context="git status -sb:\n$(git -C "$PROJECT_ROOT" status -sb)"
		context+=$'\n\n'
		context+="git diff (unstaged):\n$(git -C "$PROJECT_ROOT" diff)"
		context+=$'\n\n'
		context+="git diff --cached:\n$(git -C "$PROJECT_ROOT" diff --cached)"
	fi

	local prompt
	prompt=$(cat "$template_file")
	prompt=$(replace_token "$prompt" "{project_root}" "$PROJECT_ROOT")
	prompt=$(replace_token "$prompt" "{review_target}" "$review_target")
	prompt=$(replace_token "$prompt" "{review_context}" "$context")

	printf 'running review with %s...\n' "$runner"
	_review_run_prompt_to_file "$runner" "$prompt" "$out_file" "$runner_worktree" "$runner_task_id"
	printf '\nreview output saved to: %s\n\n' "$out_file"
	if [[ -n "$task_id" ]]; then
		_review_update_task_state "$task_id" "$out_file" "$runner"
	fi
	cat "$out_file"
}

cmd_review() {
	local target=""
	local task_id=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--task)
			shift
			task_id="${1:-}"
			[[ -n "$task_id" ]] || die "usage: orchd review [ref] | orchd review --task <task-id>"
			shift
			;;
		-h | --help)
			printf 'usage: orchd review [ref] | orchd review --task <task-id>\n'
			return 0
			;;
		*)
			if [[ -z "$target" ]]; then
				target="$1"
				shift
			else
				die "usage: orchd review [ref] | orchd review --task <task-id>"
			fi
			;;
		esac
	done
	_review_run "$target" "$task_id"
}

_review_update_task_state() {
	local task_id=$1
	local out_file=$2
	local runner=$3
	local review_state=""
	local reason=""
	if [[ -f "$out_file" ]]; then
		review_state=$(grep -E '^REVIEW_STATUS:' "$out_file" 2>/dev/null | tail -n 1 | sed 's/^REVIEW_STATUS:[[:space:]]*//')
		reason=$(grep -E '^REVIEW_REASON:' "$out_file" 2>/dev/null | tail -n 1 | sed 's/^REVIEW_REASON:[[:space:]]*//')
	fi
	review_state=$(printf '%s' "$review_state" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
	case "$review_state" in
	approved | changes_requested) ;;
	*)
		if grep -q '^No issues found\.$' "$out_file" 2>/dev/null || grep -q '^No issues found$' "$out_file" 2>/dev/null; then
			review_state="approved"
			[[ -n "$reason" ]] || reason="review found no blocking issues"
		else
			review_state="changes_requested"
			[[ -n "$reason" ]] || reason="review reported issues that should be addressed before merge"
		fi
		;;
	esac
	task_set "$task_id" "review_status" "$review_state"
	task_set "$task_id" "review_reason" "$reason"
	task_set "$task_id" "reviewed_at" "$(now_iso)"
	task_set "$task_id" "review_runner" "$runner"
	task_set "$task_id" "review_output_file" "$out_file"
}
