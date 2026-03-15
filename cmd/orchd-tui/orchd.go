package main

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

func resolveOrchdBinary() string {
	if env := strings.TrimSpace(os.Getenv("ORCHD_BIN")); env != "" {
		if isExecutable(env) {
			return env
		}
	}

	for _, candidate := range localOrchdCandidates() {
		if isExecutable(candidate) {
			return candidate
		}
	}

	if p, err := exec.LookPath("orchd"); err == nil {
		return p
	}

	return "orchd"
}

func localOrchdCandidates() []string {
	candidates := make([]string, 0, 4)
	seen := make(map[string]struct{}, 4)
	add := func(path string) {
		path = strings.TrimSpace(path)
		if path == "" {
			return
		}
		if abs, err := filepath.Abs(path); err == nil {
			path = abs
		}
		if _, ok := seen[path]; ok {
			return
		}
		seen[path] = struct{}{}
		candidates = append(candidates, path)
	}

	if exe, err := os.Executable(); err == nil {
		add(filepath.Join(filepath.Dir(exe), "orchd"))
	}

	if cwd, err := os.Getwd(); err == nil {
		add(filepath.Join(cwd, "bin", "orchd"))
	}

	return candidates
}

func isExecutable(path string) bool {
	if path == "" {
		return false
	}
	st, err := os.Stat(path)
	if err != nil {
		return false
	}
	if st.IsDir() {
		return false
	}
	return st.Mode()&0o111 != 0
}

func runOrchdJSON(bin string, cwd string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, bin, args...)
	cmd.Dir = cwd

	var out bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &stderr

	err := cmd.Run()
	if ctx.Err() == context.DeadlineExceeded {
		return nil, fmt.Errorf("command timed out: %s %s", bin, strings.Join(args, " "))
	}
	if err != nil {
		return nil, fmt.Errorf("%s %s failed: %w\n%s", bin, strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}

	return out.Bytes(), nil
}

func runOrchdCommand(bin string, cwd string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Minute)
	defer cancel()

	cmd := exec.CommandContext(ctx, bin, args...)
	cmd.Dir = cwd

	buf, err := cmd.CombinedOutput()
	output := strings.TrimSpace(string(buf))

	if ctx.Err() == context.DeadlineExceeded {
		return output, fmt.Errorf("command timed out: %s %s", bin, strings.Join(args, " "))
	}
	if err != nil {
		return output, fmt.Errorf("%s %s failed: %w", bin, strings.Join(args, " "), err)
	}

	return output, nil
}
