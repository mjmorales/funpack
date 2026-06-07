// funpack-build invocation: the single spawn primitive that runs `funpack build`
// as a subprocess (Go stdlib os/exec only — never a library import of funpack,
// spec §29). funpack resolves its project root from the process working
// directory ("." in build.odin) and writes its derived `.funpack/` products
// under that root, so the caller's tree directory becomes the subprocess cwd;
// that single wiring decision is what makes funpack's root resolution land in
// the intended tree.
//
// This primitive captures raw outcome ONLY — stdout, stderr, and the process
// exit code as distinct fields. It deliberately does NOT interpret the code into
// outcome semantics (the §29 §3 0/2 contract) and does NOT read the emitted
// NDJSON product; those are separate concerns layered on top of this capture.
package main

import (
	"bytes"
	"errors"
	"fmt"
	"os/exec"
)

// BuildResult is the raw, uninterpreted outcome of one `funpack build` spawn.
// The three captures are kept as distinct fields precisely because higher layers
// classify them independently: Stdout carries the build's success line, Stderr
// carries funpack's diagnostic on a §29 §3 exit-2, and ExitCode is the raw code
// with NO success/failure judgment applied here.
type BuildResult struct {
	Stdout   []byte
	Stderr   []byte
	ExitCode int
}

// InvokeBuild spawns `<binary> build` with treeDir as the subprocess working
// directory and captures stdout and stderr into separate buffers. The returned
// BuildResult carries the raw exit code; a non-zero funpack exit is NOT an error
// here — it is a normal, captured outcome, so err is nil and BuildResult.ExitCode
// holds the code. A non-nil error means the spawn itself could not run to a
// recorded exit (binary unspawnable, treeDir missing) — a distinct failure mode
// from "funpack ran and returned non-zero".
func InvokeBuild(binary, treeDir string) (BuildResult, error) {
	cmd := exec.Command(binary, "build")
	cmd.Dir = treeDir

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	runErr := cmd.Run()

	result := BuildResult{
		Stdout: stdout.Bytes(),
		Stderr: stderr.Bytes(),
	}

	if runErr == nil {
		// Clean spawn, exit 0.
		return result, nil
	}

	// A non-zero exit surfaces as *exec.ExitError carrying the recorded code:
	// that is a captured outcome, not a spawn failure, so it returns nil error.
	var exitErr *exec.ExitError
	if errors.As(runErr, &exitErr) {
		result.ExitCode = exitErr.ExitCode()
		return result, nil
	}

	// Anything else (binary not found/executable, cwd missing, signal kill) is a
	// genuine spawn failure: the subprocess never produced a recorded exit code.
	return result, fmt.Errorf("warden: funpack build spawn failed: %w", runErr)
}
