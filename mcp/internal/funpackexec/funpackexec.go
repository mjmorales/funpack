// Package funpackexec is the single one-shot exec wrapper every funpack
// subcommand-driving MCP tool builds on. Any verb — build, export, check, fmt,
// test, warden — flows through [Run]; the per-verb tools build their typed
// results on top of the structured [Result] this package captures.
//
// THE CENTRAL CONVENTION — a non-zero exit is NOT a Go error. funpack uses its
// exit code as data: `funpack check` exits non-zero on a failing check, `test`
// on a failing test. Run captures that code in Result.ExitCode and returns a nil
// error, so the caller (build/test/warden tools) branches on the code rather
// than on err. Only a genuine spawn/IO failure — a missing binary, a cancelled
// context, a pipe error the child never even ran past — is a Go error, wrapped
// as mcperr.CategoryExec. The exit code is pulled off *exec.ExitError via
// errors.As, so a clean non-zero exit never escapes as a hard error.
package funpackexec

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"time"

	"github.com/mjmorales/funpack/mcp/internal/funpack"
	"github.com/mjmorales/funpack/mcp/internal/mcperr"
)

// Result is the structured outcome of one funpack subcommand invocation. Args is
// the argv passed to funpack (without the binary path); Stdout and Stderr are the
// fully-captured streams; ExitCode is the process exit status — zero on success,
// non-zero when funpack used the code to signal a domain outcome (a failing
// check, a failing test); Duration is the wall-clock span of the call.
type Result struct {
	Args     []string
	Stdout   string
	Stderr   string
	ExitCode int
	Duration time.Duration
}

// Run executes `<bin.Path> args...` as a one-shot child process in the caller's
// working directory. It is RunInDir with an empty dir; see RunInDir for the full
// capture and error contract.
func Run(ctx context.Context, bin funpack.Binary, args ...string) (Result, error) {
	return RunInDir(ctx, "", bin, args...)
}

// RunInDir executes `<bin.Path> args...` as a one-shot child process whose working
// directory is dir, capturing stdout, stderr, and the exit code into a Result.
// funpack verbs (build/check/fmt/test/warden) operate on the §14 project tree at
// the process cwd — there is no project-path flag — so dir is how a tool points
// funpack at a specific project. An empty dir inherits the MCP server's cwd.
//
// ctx cancels the child via exec.CommandContext: a cancelled or deadline-exceeded
// context terminates the process and returns a CategoryExec error.
//
// A NON-ZERO exit is captured in Result.ExitCode with a nil error — the caller
// branches on the code. A genuine spawn/IO failure (the binary cannot be started,
// the context was cancelled, a pipe broke) returns an *mcperr.Error of
// CategoryExec; the partial Result (whatever was captured before the failure) is
// returned alongside so a caller can still inspect captured output.
func RunInDir(ctx context.Context, dir string, bin funpack.Binary, args ...string) (Result, error) {
	start := time.Now()

	cmd := exec.CommandContext(ctx, bin.Path, args...)
	cmd.Dir = dir
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	runErr := cmd.Run()

	res := Result{
		Args:     args,
		Stdout:   stdout.String(),
		Stderr:   stderr.String(),
		Duration: time.Since(start),
	}

	if runErr == nil {
		// Clean zero exit.
		res.ExitCode = 0
		return res, nil
	}

	// A cancelled or expired context is a genuine spawn/IO failure regardless of
	// how the OS reported the child's death. CommandContext kills the child on
	// cancellation, and the kernel may surface that as a signal-kill *exec.ExitError
	// (e.g. 137) rather than a context error — so check ctx before unwrapping the
	// code, lest a cancellation be mistaken for a clean non-zero exit.
	if ctxErr := ctx.Err(); ctxErr != nil {
		res.ExitCode = -1
		return res, mcperr.Wrap(mcperr.CategoryExec,
			fmt.Sprintf("running `funpack %s` was cancelled", joinArgs(args)), ctxErr)
	}

	// A non-zero exit surfaces as *exec.ExitError carrying the code. Pull the
	// code off and return success at the Go level: the exit is data, not a fault.
	var exitErr *exec.ExitError
	if errors.As(runErr, &exitErr) {
		res.ExitCode = exitErr.ExitCode()
		return res, nil
	}

	// Anything else — binary missing/not startable, a pipe IO fault — is a
	// genuine spawn/IO failure. Surface the partial Result with the error.
	res.ExitCode = -1
	return res, mcperr.Wrap(mcperr.CategoryExec,
		fmt.Sprintf("running `funpack %s` failed", joinArgs(args)), runErr)
}

// joinArgs renders argv for an error message ("build --release ./game").
func joinArgs(args []string) string {
	out := ""
	for i, a := range args {
		if i > 0 {
			out += " "
		}
		out += a
	}
	return out
}
