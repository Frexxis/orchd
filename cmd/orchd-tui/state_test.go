package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSplitDeps(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want []string
	}{
		{name: "empty", in: "", want: nil},
		{name: "none", in: "none", want: nil},
		{name: "single", in: "task-a", want: []string{"task-a"}},
		{name: "multi", in: "task-a, task-b,task-c", want: []string{"task-a", "task-b", "task-c"}},
		{name: "spaces", in: "  task-a  ,   task-b  ", want: []string{"task-a", "task-b"}},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := splitDeps(tc.in)
			if len(got) != len(tc.want) {
				t.Fatalf("splitDeps(%q) len=%d want=%d", tc.in, len(got), len(tc.want))
			}
			for i := range got {
				if got[i] != tc.want[i] {
					t.Fatalf("splitDeps(%q)[%d]=%q want=%q", tc.in, i, got[i], tc.want[i])
				}
			}
		})
	}
}

func TestLoadQueueItems(t *testing.T) {
	root := t.TempDir()
	queueDir := filepath.Join(root, ".orchd")
	if err := os.MkdirAll(queueDir, 0o755); err != nil {
		t.Fatalf("mkdir queue dir: %v", err)
	}

	content := "# queue\n" +
		"- [ ] 2026-03-03T10:00:00Z pending idea\n" +
		"- [>] 2026-03-03T10:01:00Z active idea\n" +
		"- [x] 2026-03-03T10:02:00Z done idea\n" +
		"- [-] 2026-03-03T10:03:00Z cancelled idea\n"

	if err := os.WriteFile(filepath.Join(queueDir, "queue.md"), []byte(content), 0o644); err != nil {
		t.Fatalf("write queue: %v", err)
	}

	items, err := loadQueueItems(root)
	if err != nil {
		t.Fatalf("loadQueueItems: %v", err)
	}

	if len(items) != 4 {
		t.Fatalf("len(items)=%d want=4", len(items))
	}

	if items[0].Status != "pending" || items[1].Status != "active" || items[2].Status != "done" || items[3].Status != "cancelled" {
		t.Fatalf("unexpected statuses: %#v", items)
	}

	if items[0].LineNo <= 0 || items[1].LineNo <= 0 {
		t.Fatalf("expected line numbers to be captured: %#v", items)
	}
}

func TestStatusASCII(t *testing.T) {
	if got := statusASCII("merged"); got != "[x]" {
		t.Fatalf("merged icon = %q want [x]", got)
	}
	if got := statusASCII("running"); got != "[>]" {
		t.Fatalf("running icon = %q want [>]", got)
	}
	if got := statusASCII("stale"); got != "[~]" {
		t.Fatalf("stale icon = %q want [~]", got)
	}
	if got := statusASCII("unknown-value"); got != "[-]" {
		t.Fatalf("unknown icon = %q want [-]", got)
	}
}

func TestStateJSONUnmarshalIncludesNeedsInput(t *testing.T) {
	raw := `{
		"project_root": "/tmp/demo",
		"base_branch": "main",
		"worktree_dir": ".worktrees",
		"worker_runner": "codex",
		"max_parallel": 3,
		"counts": {"total":1,"pending":0,"running":0,"done":0,"merged":0,"split":0,"failed":0,"conflict":0,"needs_input":1},
		"ready": {"spawn":0,"check":0,"merge":0},
		"finisher": {"state":"next_phase_available","reason":"follow-on work exists","updated_at":"2026-03-24T00:00:00Z"},
		"scheduler": {
			"last_action": "merge",
			"last_reason": "merge-ready work exists",
			"updated_at": "2026-03-24T00:00:00Z",
			"autopilot": {"action":"merge","reason":"merge-ready work exists","updated_at":"2026-03-24T00:00:00Z"},
			"orchestrate": {"action":"check","reason":"completed worker sessions need checking","updated_at":"2026-03-24T00:01:00Z"}
		},
		"orchestrator": {
			"route_role": "architect",
			"selected_runner": "claude",
			"route_reason": "using preferred runner claude for role architect",
			"route_fallback_used": false,
			"session_mode": "sticky",
			"last_result": "CONTINUE",
			"last_reason": "keep going",
			"last_idle_decision": "reminder_sent",
			"last_reminder_reason": "system reminder"
		},
		"tasks": [{
			"id": "t1",
			"title": "Need decision",
			"role": "domain",
			"status": "needs_input",
			"effective_status": "needs_input",
			"deps": "",
			"branch": "agent-t1",
			"worktree": "/tmp/demo/.worktrees/agent-t1",
			"runner": "codex",
			"routing_role": "builder",
			"selected_runner": "codex",
			"routing_default_runner": "codex",
			"routing_candidates": "codex,claude",
			"routing_fallback_used": false,
			"routing_fallback_count": 1,
			"routing_reason": "using preferred runner codex for role builder",
			"session": "orchd-agent-t1",
			"session_state": "stale",
			"agent_alive": false,
			"attempts": 1,
			"checked_at": "",
			"merged_at": "",
			"last_failure_reason": "",
			"verification_tier": "targeted",
			"verification_reason": "medium risk defaults to targeted",
			"failure_class": "needs_input",
			"failure_summary": "Need decision",
			"failure_streak": 2,
			"recovery_policy": "needs_input",
			"recovery_next_action": "ask_user",
			"recovery_policy_reason": "blocked on product decision",
			"review_status": "",
			"review_reason": "",
			"review_required": true,
			"reviewed_at": "",
			"review_runner": "",
			"review_output_file": "",
			"merge_gate_status": "blocked",
			"merge_gate_reason": "needs approved review",
			"merge_required_verification_tier": "full",
			"split_children": "child-a,child-b",
			"log_file": "/tmp/demo/.orchd/logs/t1.jsonl",
			"needs_input": {
				"source": "json",
				"file": "/tmp/demo/.worktrees/agent-t1/.orchd_needs_input.json",
				"code": "decision_required",
				"summary": "Need a product decision",
				"question": "Provider A or B?",
				"blocking": "true",
				"options": "provider_a | provider_b",
				"error": ""
			}
		}]
	}`

	var st orchState
	if err := json.Unmarshal([]byte(raw), &st); err != nil {
		t.Fatalf("unmarshal state json: %v", err)
	}
	if len(st.Tasks) != 1 {
		t.Fatalf("len(tasks)=%d want=1", len(st.Tasks))
	}
	task := st.Tasks[0]
	if task.EffectiveStatus != "needs_input" {
		t.Fatalf("effective status=%q want needs_input", task.EffectiveStatus)
	}
	if task.SessionState != "stale" {
		t.Fatalf("session state=%q want stale", task.SessionState)
	}
	if task.NeedsInput == nil {
		t.Fatalf("needs_input payload should be present")
	}
	if task.NeedsInput.Code != "decision_required" {
		t.Fatalf("needs_input code=%q want decision_required", task.NeedsInput.Code)
	}
	if st.Scheduler.LastAction != "merge" {
		t.Fatalf("scheduler last action=%q want merge", st.Scheduler.LastAction)
	}
	if st.Finisher.State != "next_phase_available" {
		t.Fatalf("finisher state=%q want next_phase_available", st.Finisher.State)
	}
	if !task.ReviewRequired {
		t.Fatalf("review_required should be true")
	}
	if task.SplitChildren != "child-a,child-b" {
		t.Fatalf("split children=%q want child-a,child-b", task.SplitChildren)
	}
}

func TestUpdateQueueItemMarker(t *testing.T) {
	root := t.TempDir()
	queueDir := filepath.Join(root, ".orchd")
	if err := os.MkdirAll(queueDir, 0o755); err != nil {
		t.Fatalf("mkdir queue dir: %v", err)
	}

	content := "# queue\n" +
		"- [ ] 2026-03-03T10:00:00Z pending idea\n" +
		"- [>] 2026-03-03T10:01:00Z active idea\n"

	queuePath := filepath.Join(queueDir, "queue.md")
	if err := os.WriteFile(queuePath, []byte(content), 0o644); err != nil {
		t.Fatalf("write queue: %v", err)
	}

	if err := updateQueueItemMarker(root, 2, "-"); err != nil {
		t.Fatalf("updateQueueItemMarker: %v", err)
	}

	updated, err := os.ReadFile(queuePath)
	if err != nil {
		t.Fatalf("read queue: %v", err)
	}

	s := string(updated)
	if !containsLine(s, "- [-] 2026-03-03T10:00:00Z pending idea") {
		t.Fatalf("expected first queue item to be cancelled, got:\n%s", s)
	}
}

func TestFilterLines(t *testing.T) {
	lines := []string{"alpha", "beta", "Gamma", "delta"}
	filtered := filterLines(lines, "ga")
	if len(filtered) != 1 || filtered[0] != "Gamma" {
		t.Fatalf("unexpected filtered lines: %#v", filtered)
	}

	all := filterLines(lines, "")
	if len(all) != len(lines) {
		t.Fatalf("expected all lines for empty query, got %d", len(all))
	}
}

func containsLine(content string, target string) bool {
	for _, line := range strings.Split(content, "\n") {
		if line == target {
			return true
		}
	}
	return false
}
