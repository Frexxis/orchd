package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var queueLinePattern = regexp.MustCompile(`^- \[([ x>-])\] ([0-9]{4}-[0-9]{2}-[0-9]{2}T[^ ]+) (.*)$`)

func loadQueueItems(projectRoot string) ([]queueItem, error) {
	path := filepath.Join(projectRoot, ".orchd", "queue.md")
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	defer f.Close()

	items := make([]queueItem, 0, 16)
	scanner := bufio.NewScanner(f)
	lineNo := 0
	for scanner.Scan() {
		lineNo++
		line := scanner.Text()
		matches := queueLinePattern.FindStringSubmatch(line)
		if len(matches) != 4 {
			continue
		}

		marker := matches[1]
		status := "unknown"
		switch marker {
		case " ":
			status = "pending"
		case ">":
			status = "active"
		case "x":
			status = "done"
		case "-":
			status = "cancelled"
		}

		items = append(items, queueItem{
			LineNo:    lineNo,
			Marker:    marker,
			Status:    status,
			Timestamp: matches[2],
			Idea:      strings.TrimSpace(matches[3]),
		})
	}

	if err := scanner.Err(); err != nil {
		return nil, err
	}

	return items, nil
}

func updateQueueItemMarker(projectRoot string, lineNo int, marker string) error {
	if lineNo <= 0 {
		return fmt.Errorf("invalid queue line number: %d", lineNo)
	}
	if marker != " " && marker != ">" && marker != "x" && marker != "-" {
		return fmt.Errorf("invalid queue marker: %q", marker)
	}

	path := filepath.Join(projectRoot, ".orchd", "queue.md")
	buf, err := os.ReadFile(path)
	if err != nil {
		return err
	}

	original := strings.ReplaceAll(string(buf), "\r\n", "\n")
	hadTrailingNewline := strings.HasSuffix(original, "\n")
	lines := strings.Split(original, "\n")

	if lineNo > len(lines) {
		return fmt.Errorf("queue line out of range: %d", lineNo)
	}

	idx := lineNo - 1
	line := lines[idx]
	matches := queueLinePattern.FindStringSubmatch(line)
	if len(matches) != 4 {
		return fmt.Errorf("line %d is not a queue item", lineNo)
	}

	lines[idx] = fmt.Sprintf("- [%s] %s %s", marker, matches[2], matches[3])

	updated := strings.Join(lines, "\n")
	if hadTrailingNewline && !strings.HasSuffix(updated, "\n") {
		updated += "\n"
	}

	return os.WriteFile(path, []byte(updated), 0o644)
}
