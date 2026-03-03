package main

import (
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
	if got := statusASCII("unknown-value"); got != "[-]" {
		t.Fatalf("unknown icon = %q want [-]", got)
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
