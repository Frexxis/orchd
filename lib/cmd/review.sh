#!/usr/bin/env bash
# lib/cmd/review.sh - orchd review command
# Runs a review-only agent session against repo changes

cmd_review() {
	local target="${1:-}"

	require_project

	local runner
	runner=$(detect_runner)
	runner_validate "$runner"

	local template_file="$ORCHD_LIB_DIR/../templates/review.prompt"
	if [[ ! -f "$template_file" ]]; then
		die "review template not found: $template_file"
	fi

	local review_target="working tree"
	local context=""
	if [[ -n "$target" ]]; then
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

	local out_file="$ORCHD_DIR/review_output.txt"
	case "$runner" in
	codex)
		local codex_bin
		codex_bin=$(config_get "codex_bin" "codex")
		"$codex_bin" exec "$prompt" -C "$PROJECT_ROOT" --json 2>/dev/null |
			_extract_text_from_jsonl >"$out_file" || {
			die "codex review failed"
		}
		;;
	claude)
		local claude_bin
		claude_bin=$(config_get "claude_bin" "claude")
		(cd "$PROJECT_ROOT" && "$claude_bin" -p "$prompt" --output-format text 2>/dev/null >"$out_file") || {
			die "claude review failed"
		}
		;;
	opencode)
		(cd "$PROJECT_ROOT" && opencode -p "$prompt" 2>/dev/null >"$out_file") || {
			die "opencode review failed"
		}
		;;
	aider)
		(cd "$PROJECT_ROOT" && aider --message "$prompt" --yes --no-git 2>/dev/null >"$out_file") || {
			die "aider review failed"
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
		custom_cmd=$(replace_token "$custom_cmd" "{task_id}" "$(printf '%q' "review")")
		custom_cmd=$(replace_token "$custom_cmd" "{log_file}" "$(printf '%q' "$out_file")")
		eval "$custom_cmd" >"$out_file" 2>/dev/null || {
			die "custom review failed"
		}
		;;
	*)
		die "unsupported runner for review: $runner"
		;;
	esac

	printf '\nreview output saved to: %s\n\n' "$out_file"
	cat "$out_file"
}
