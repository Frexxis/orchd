package main

import (
	"fmt"
	"sort"
	"strings"
	"time"
)

func statusASCII(status string) string {
	switch status {
	case "merged":
		return "[x]"
	case "running":
		return "[>]"
	case "pending":
		return "[ ]"
	case "failed":
		return "[!]"
	case "needs_input":
		return "[?]"
	case "conflict":
		return "[c]"
	case "done":
		return "[d]"
	default:
		return "[-]"
	}
}

func compactDuration(raw string) string {
	if strings.TrimSpace(raw) == "" {
		return "-"
	}
	t, err := time.Parse(time.RFC3339, raw)
	if err != nil {
		return "-"
	}
	d := time.Since(t)
	if d < 0 {
		d = 0
	}
	if d < time.Minute {
		return fmt.Sprintf("%ds", int(d.Seconds()))
	}
	if d < time.Hour {
		return fmt.Sprintf("%dm", int(d.Minutes()))
	}
	return fmt.Sprintf("%dh%02dm", int(d.Hours()), int(d.Minutes())%60)
}

func wrapLines(lines []string, max int) []string {
	if len(lines) <= max {
		return lines
	}
	return append([]string(nil), lines[len(lines)-max:]...)
}

func firstLine(text string) string {
	text = strings.TrimSpace(text)
	if text == "" {
		return ""
	}
	parts := strings.Split(text, "\n")
	if len(parts) == 0 {
		return ""
	}
	return strings.TrimSpace(parts[0])
}

func sortedTaskIDs(tasks []taskState) []string {
	ids := make([]string, 0, len(tasks))
	for _, t := range tasks {
		ids = append(ids, t.ID)
	}
	sort.Strings(ids)
	return ids
}

func filterLines(lines []string, query string) []string {
	query = strings.TrimSpace(query)
	if query == "" {
		return lines
	}

	q := strings.ToLower(query)
	filtered := make([]string, 0, len(lines))
	for _, line := range lines {
		if strings.Contains(strings.ToLower(line), q) {
			filtered = append(filtered, line)
		}
	}
	return filtered
}
