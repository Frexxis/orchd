package main

import (
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/charmbracelet/glamour"
)

func fetchState(bin string, cwd string) (orchState, error) {
	buf, err := runOrchdJSON(bin, cwd, "state", "--json")
	if err != nil {
		return orchState{}, err
	}

	var st orchState
	if err := json.Unmarshal(buf, &st); err != nil {
		return orchState{}, fmt.Errorf("failed to parse orchd state JSON: %w", err)
	}

	for i := range st.Tasks {
		st.Tasks[i].DepsSlice = splitDeps(st.Tasks[i].Deps)
	}

	sort.Slice(st.Tasks, func(i, j int) bool {
		return st.Tasks[i].ID < st.Tasks[j].ID
	})

	return st, nil
}

func splitDeps(raw string) []string {
	raw = strings.TrimSpace(raw)
	if raw == "" || strings.EqualFold(raw, "none") {
		return nil
	}
	parts := strings.Split(raw, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		out = append(out, p)
	}
	return out
}

func loadTaskDetails(projectRoot string, taskID string) (taskDetails, error) {
	if projectRoot == "" || taskID == "" {
		return taskDetails{}, nil
	}
	taskDir := filepath.Join(projectRoot, ".orchd", "tasks", taskID)

	details := taskDetails{}
	details.Description = strings.TrimSpace(readTextFile(filepath.Join(taskDir, "description")))
	details.Acceptance = strings.TrimSpace(readTextFile(filepath.Join(taskDir, "acceptance")))
	details.LastCheck = strings.TrimSpace(readTextFile(filepath.Join(taskDir, "last_check.txt")))
	details.StartedAt = strings.TrimSpace(readTextFile(filepath.Join(taskDir, "started_at")))
	details.CheckPassed = readIntFile(filepath.Join(taskDir, "check_passed"))
	details.CheckTotal = readIntFile(filepath.Join(taskDir, "check_total"))
	details.CheckFailed = readIntFile(filepath.Join(taskDir, "check_failed"))

	return details, nil
}

func loadMemoryFiles(projectRoot string) ([]memoryFile, error) {
	base := filepath.Join(projectRoot, "docs", "memory")
	if _, err := os.Stat(base); err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}

	files := make([]memoryFile, 0, 12)
	err := filepath.WalkDir(base, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if d.IsDir() {
			return nil
		}
		if filepath.Ext(path) != ".md" {
			return nil
		}
		st, statErr := os.Stat(path)
		if statErr != nil {
			return nil
		}
		rel, relErr := filepath.Rel(base, path)
		if relErr != nil {
			rel = filepath.Base(path)
		}
		files = append(files, memoryFile{Name: rel, Path: path, Bytes: st.Size()})
		return nil
	})
	if err != nil {
		return nil, err
	}

	sort.Slice(files, func(i, j int) bool {
		left := memoryPriority(files[i].Name)
		right := memoryPriority(files[j].Name)
		if left != right {
			return left < right
		}
		return files[i].Name < files[j].Name
	})

	return files, nil
}

func memoryPriority(name string) int {
	switch name {
	case "projectbrief.md":
		return 0
	case "systemPatterns.md":
		return 1
	case "techContext.md":
		return 2
	case "activeContext.md":
		return 3
	case "progress.md":
		return 4
	default:
		if strings.HasPrefix(name, "lessons/") {
			return 5
		}
		return 6
	}
}

func renderMarkdown(path string, width int) string {
	content := readTextFile(path)
	if strings.TrimSpace(content) == "" {
		return "(empty)"
	}

	renderer, err := glamour.NewTermRenderer(
		glamour.WithAutoStyle(),
		glamour.WithWordWrap(width),
	)
	if err != nil {
		return content
	}

	out, err := renderer.Render(content)
	if err != nil {
		return content
	}
	return strings.TrimSpace(out)
}

func detectAutopilotRunning(projectRoot string) (bool, error) {
	pidPath := filepath.Join(projectRoot, ".orchd", "autopilot.pid")
	pidRaw := strings.TrimSpace(readTextFile(pidPath))
	if pidRaw == "" {
		return false, nil
	}

	pid, err := strconv.Atoi(pidRaw)
	if err != nil || pid <= 0 {
		return false, nil
	}

	if processExists(pid) {
		return true, nil
	}
	return false, nil
}

func readTextFile(path string) string {
	if path == "" {
		return ""
	}
	buf, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.ReplaceAll(string(buf), "\r\n", "\n")
}

func readIntFile(path string) int {
	raw := strings.TrimSpace(readTextFile(path))
	if raw == "" {
		return 0
	}
	v, err := strconv.Atoi(raw)
	if err != nil {
		return 0
	}
	return v
}
