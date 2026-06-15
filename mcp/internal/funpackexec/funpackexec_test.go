package funpackexec

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"testing"
	"time"

	"github.com/mjmorales/funpack/mcp/internal/funpack"
	"github.com/mjmorales/funpack/mcp/internal/mcperr"
)

// writeFakeBin writes an executable shell script that prints a fixed line to
// stdout, a fixed line to stderr, and exits with code. It is POSIX-only — the
// shebang does not apply on Windows, where the suite skips. Returns the path.
func writeFakeBin(t *testing.T, code int) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("fake shell-script binary is POSIX-only")
	}
	path := filepath.Join(t.TempDir(), "funpack")
	script := "#!/bin/sh\n" +
		"printf 'OUT-LINE\\n'\n" +
		"printf 'ERR-LINE\\n' 1>&2\n" +
		"exit " + strconv.Itoa(code) + "\n"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake binary: %v", err)
	}
	return path
}

// writeSleeperBin writes an executable script that sleeps long enough to be
// cancelled by a context before it would exit, so a cancellation test never
// races the process to completion.
func writeSleeperBin(t *testing.T) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("fake shell-script binary is POSIX-only")
	}
	path := filepath.Join(t.TempDir(), "funpack")
	script := "#!/bin/sh\nsleep 30\n"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatalf("write sleeper binary: %v", err)
	}
	return path
}

// TestRunZeroExitCapturesStreams proves a clean exit returns no Go error and
// captures stdout, stderr, the zero exit code, the argv, and a non-negative
// duration.
func TestRunZeroExitCapturesStreams(t *testing.T) {
	bin := funpack.Binary{Path: writeFakeBin(t, 0)}

	res, err := Run(context.Background(), bin, "build", "--release")
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.ExitCode != 0 {
		t.Fatalf("ExitCode = %d, want 0", res.ExitCode)
	}
	if res.Stdout != "OUT-LINE\n" {
		t.Fatalf("Stdout = %q, want %q", res.Stdout, "OUT-LINE\n")
	}
	if res.Stderr != "ERR-LINE\n" {
		t.Fatalf("Stderr = %q, want %q", res.Stderr, "ERR-LINE\n")
	}
	if len(res.Args) != 2 || res.Args[0] != "build" || res.Args[1] != "--release" {
		t.Fatalf("Args = %v, want [build --release]", res.Args)
	}
	if res.Duration < 0 {
		t.Fatalf("Duration = %v, want >= 0", res.Duration)
	}
}

// TestRunNonZeroExitIsNotAnError is the central convention: a non-zero exit is
// captured in Result.ExitCode with a nil Go error, and the streams are still
// captured so the caller can branch on the code and read the diagnostics.
func TestRunNonZeroExitIsNotAnError(t *testing.T) {
	bin := funpack.Binary{Path: writeFakeBin(t, 7)}

	res, err := Run(context.Background(), bin, "test")
	if err != nil {
		t.Fatalf("Run returned a Go error on a non-zero exit: %v", err)
	}
	if res.ExitCode != 7 {
		t.Fatalf("ExitCode = %d, want 7", res.ExitCode)
	}
	if res.Stdout != "OUT-LINE\n" {
		t.Fatalf("Stdout = %q, want %q", res.Stdout, "OUT-LINE\n")
	}
	if res.Stderr != "ERR-LINE\n" {
		t.Fatalf("Stderr = %q, want %q", res.Stderr, "ERR-LINE\n")
	}
}

// TestRunMissingBinaryIsExecError proves a path that cannot be started fails with
// an *mcperr.Error of CategoryExec (a genuine spawn failure, not a captured code).
func TestRunMissingBinaryIsExecError(t *testing.T) {
	bin := funpack.Binary{Path: filepath.Join(t.TempDir(), "does-not-exist")}

	res, err := Run(context.Background(), bin, "build")
	if err == nil {
		t.Fatal("Run succeeded with a non-existent binary path")
	}
	if !errors.Is(err, mcperr.New(mcperr.CategoryExec, "")) {
		t.Fatalf("err category is not exec: %v", err)
	}
	if res.ExitCode != -1 {
		t.Fatalf("ExitCode = %d, want -1 on spawn failure", res.ExitCode)
	}
}

// TestRunCancelledContextIsExecError proves a context cancelled mid-run
// terminates the child and surfaces a CategoryExec error rather than blocking or
// returning a captured code.
func TestRunCancelledContextIsExecError(t *testing.T) {
	bin := funpack.Binary{Path: writeSleeperBin(t)}

	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()

	_, err := Run(ctx, bin, "build")
	if err == nil {
		t.Fatal("Run succeeded despite a cancelled context")
	}
	if !errors.Is(err, mcperr.New(mcperr.CategoryExec, "")) {
		t.Fatalf("err category is not exec: %v", err)
	}
}
