// funpack-binary discovery: warden's only coupling to funpack is spawning its
// CLI over a process boundary (spec §29 — never a library link), so before it
// can invoke anything it must resolve WHICH executable to spawn. Discovery is
// deterministic and machine-path-free: every candidate is derived from
// environment or repo layout, never a baked-in absolute path. The precedence is
// fixed and total — an explicit override wins, then the conventionally-built
// in-repo binary, then a PATH lookup — and exhausting all three yields a typed
// not-found error the caller can branch on.
package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
)

// FunpackBinEnv is the explicit-override environment variable. When set to a
// path to an existing executable, it short-circuits the whole precedence chain
// — this is the seam tests use to point warden at a stub binary, and the seam
// an operator uses to pin a specific funpack build.
const FunpackBinEnv = "FUNPACK_BIN"

// repoBinaryRelPath is the conventionally-built funpack executable's location
// relative to the repo root: `odin build . -out:funpack` in funpack/ emits
// `funpack/funpack` (gitignored, rebuilt on demand). Resolving against the
// caller-supplied repo root keeps this a pure function of layout with no
// machine-specific component.
var repoBinaryRelPath = filepath.Join("funpack", "funpack")

// ErrFunpackNotFound is the typed sentinel returned when no discovery source
// resolves a usable funpack binary. Callers match it with errors.Is to
// distinguish "no binary anywhere" from an invocation failure of a binary that
// WAS found.
var ErrFunpackNotFound = errors.New("warden: no funpack binary found via FUNPACK_BIN, repo build, or PATH")

// Discovery configures funpack-binary resolution. Both fields are injectable so
// the precedence is exercisable in a unit test without touching the ambient
// process environment or a real repo checkout:
//   - RepoRoot anchors the conventionally-built-binary candidate; when empty the
//     repo-build step is skipped (there is no root to derive `funpack/funpack`
//     from) rather than guessed.
//   - LookupEnv reads the override variable; nil falls back to os.LookupEnv so a
//     zero-value Discovery uses the live environment.
type Discovery struct {
	RepoRoot  string
	LookupEnv func(string) (string, bool)
}

// lookupEnv returns the configured env reader or the process default, so a
// zero-value Discovery resolves against the live environment.
func (d Discovery) lookupEnv(key string) (string, bool) {
	if d.LookupEnv != nil {
		return d.LookupEnv(key)
	}
	return os.LookupEnv(key)
}

// DiscoverFunpack resolves the funpack executable by fixed precedence:
//
//  1. FUNPACK_BIN — when set, the override is authoritative: a usable target
//     returns it; a set-but-unusable target is a hard error, NOT a silent
//     fall-through, so a typo in the override surfaces instead of masquerading
//     as a PATH hit.
//  2. <RepoRoot>/funpack/funpack — the conventionally-built in-repo binary, when
//     a RepoRoot is configured and the path is a usable executable.
//  3. exec.LookPath("funpack") — a funpack on PATH.
//
// Exhausting all three returns ErrFunpackNotFound. The returned path is always
// absolute so a later os/exec invocation is independent of the subprocess cwd.
func (d Discovery) DiscoverFunpack() (string, error) {
	if override, ok := d.lookupEnv(FunpackBinEnv); ok && override != "" {
		if err := checkExecutable(override); err != nil {
			return "", fmt.Errorf("warden: %s=%q is not a usable funpack binary: %w", FunpackBinEnv, override, err)
		}
		return filepath.Abs(override)
	}

	if d.RepoRoot != "" {
		candidate := filepath.Join(d.RepoRoot, repoBinaryRelPath)
		if checkExecutable(candidate) == nil {
			return filepath.Abs(candidate)
		}
	}

	if onPath, err := exec.LookPath("funpack"); err == nil {
		return filepath.Abs(onPath)
	}

	return "", ErrFunpackNotFound
}

// checkExecutable reports whether path names a regular file with at least one
// execute bit set. It is the shared usability test the override and repo-build
// candidates both gate on; PATH candidates are vetted by exec.LookPath itself.
func checkExecutable(path string) error {
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	if info.IsDir() {
		return fmt.Errorf("%s is a directory, not an executable", path)
	}
	if info.Mode().Perm()&0o111 == 0 {
		return fmt.Errorf("%s is not executable", path)
	}
	return nil
}
