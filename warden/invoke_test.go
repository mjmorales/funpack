package main

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// minimalTreeDir resolves the committed synthetic §14 fixture tree the spawn
// tests run the stub binary against.
func minimalTreeDir(t *testing.T) string {
	t.Helper()
	dir, err := filepath.Abs(filepath.Join("testdata", "minimal_tree"))
	if err != nil {
		t.Fatalf("abs testdata tree: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "funpack_configs")); err != nil {
		t.Fatalf("fixture tree missing funpack_configs/: %v", err)
	}
	return dir
}

// writeStubFunpack writes a shell stub that stands in for the funpack binary:
// it echoes a marker plus its own working directory to stdout, a marker to
// stderr, and exits with exitCode. Echoing `pwd` is how the test proves warden
// set the subprocess cwd to the supplied tree.
func writeStubFunpack(t *testing.T, exitCode int) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "funpack-stub")
	script := "#!/bin/sh\n" +
		"echo \"stub stdout verb=$1 cwd=$(pwd)\"\n" +
		"echo \"stub stderr verb=$1\" 1>&2\n" +
		"exit " + strconv.Itoa(exitCode) + "\n"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatalf("write stub: %v", err)
	}
	return path
}

func TestInvokeBuildCapturesAndSetsCwd(t *testing.T) {
	tree := minimalTreeDir(t)
	stub := writeStubFunpack(t, 0)

	result, err := InvokeBuild(stub, tree)
	if err != nil {
		t.Fatalf("unexpected spawn error: %v", err)
	}

	stdout := string(result.Stdout)
	// The stub was invoked with the `build` verb.
	if !strings.Contains(stdout, "verb=build") {
		t.Errorf("stdout missing build verb, got %q", stdout)
	}
	// cwd resolution: the subprocess pwd must be the supplied tree. macOS /var ->
	// /private/var symlinking means the captured pwd may be the resolved form, so
	// compare against the EvalSymlinks of the tree.
	wantCwd := evalSymlinks(t, tree)
	if !strings.Contains(stdout, "cwd="+wantCwd) {
		t.Errorf("subprocess cwd not the tree dir: want cwd=%q in stdout, got %q", wantCwd, stdout)
	}
	if got := string(result.Stderr); !strings.Contains(got, "stub stderr") {
		t.Errorf("stderr not captured separately, got %q", got)
	}
	if result.ExitCode != 0 {
		t.Errorf("exit code = %d, want 0", result.ExitCode)
	}
}

func TestInvokeBuildCapturesNonZeroExit(t *testing.T) {
	tree := minimalTreeDir(t)
	// 2 is funpack's §29 §3 malformed-tree/compile-error code; this story captures
	// it raw without classifying it.
	stub := writeStubFunpack(t, 2)

	result, err := InvokeBuild(stub, tree)
	if err != nil {
		t.Fatalf("a non-zero funpack exit must be a captured outcome, not a spawn error: %v", err)
	}
	if result.ExitCode != 2 {
		t.Errorf("exit code = %d, want 2", result.ExitCode)
	}
	if got := string(result.Stderr); !strings.Contains(got, "stub stderr") {
		t.Errorf("stderr not captured on non-zero exit, got %q", got)
	}
}

func TestInvokeBuildSpawnFailureIsError(t *testing.T) {
	tree := minimalTreeDir(t)
	// A path that does not name an executable is a genuine spawn failure — a
	// distinct mode from "funpack ran and returned non-zero".
	_, err := InvokeBuild(filepath.Join(t.TempDir(), "nonexistent-funpack"), tree)
	if err == nil {
		t.Fatal("expected a spawn error for a missing binary, got nil")
	}
}

func evalSymlinks(t *testing.T, p string) string {
	t.Helper()
	resolved, err := filepath.EvalSymlinks(p)
	if err != nil {
		t.Fatalf("eval symlinks %s: %v", p, err)
	}
	return resolved
}
