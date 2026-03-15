package main

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestResolveOrchdBinaryPrefersLocalOverPATH(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("executable-bit checks are POSIX-specific")
	}

	root := t.TempDir()
	localBin := filepath.Join(root, "bin", "orchd")
	pathDir := filepath.Join(root, "path-bin")
	pathBin := filepath.Join(pathDir, "orchd")

	writeExecutable(t, localBin)
	writeExecutable(t, pathBin)

	oldWD, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	if err := os.Chdir(root); err != nil {
		t.Fatalf("chdir: %v", err)
	}
	t.Cleanup(func() {
		_ = os.Chdir(oldWD)
	})

	t.Setenv("ORCHD_BIN", "")
	t.Setenv("PATH", pathDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	got := resolveOrchdBinary()
	if got != localBin {
		t.Fatalf("resolveOrchdBinary()=%q want local %q", got, localBin)
	}
}

func TestResolveOrchdBinaryHonorsExecutableEnvOverride(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("executable-bit checks are POSIX-specific")
	}

	root := t.TempDir()
	override := filepath.Join(root, "custom", "orchd")
	pathDir := filepath.Join(root, "path-bin")
	pathBin := filepath.Join(pathDir, "orchd")

	writeExecutable(t, override)
	writeExecutable(t, pathBin)

	t.Setenv("ORCHD_BIN", override)
	t.Setenv("PATH", pathDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	got := resolveOrchdBinary()
	if got != override {
		t.Fatalf("resolveOrchdBinary()=%q want override %q", got, override)
	}
}

func writeExecutable(t *testing.T, path string) {
	t.Helper()

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", filepath.Dir(path), err)
	}
	if err := os.WriteFile(path, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
	if err := os.Chmod(path, 0o755); err != nil {
		t.Fatalf("chmod %s: %v", path, err)
	}
}
