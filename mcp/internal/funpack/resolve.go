// Package funpack resolves the funpack binary the MCP server drives and runs a
// version preflight against the compiled contract compat policy.
//
// The resolver NEVER parses funpack's human `version` text. funpack exposes
// `funpack version --json` emitting exactly {"version":"…","schemas":{…}}; this
// package consumes that JSON through the generated contract types
// (contract.VersionInfo / contract.VersionArgv). See ADR
// 2026-06-15-funpack-api-contract-dual-codegen.
//
// All failures are *mcperr.Error of CategoryResolver, so a tool boundary can map
// them with mcperr.ToolError and the model can read the category and self-correct.
package funpack

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/mjmorales/funpack/mcp/internal/contract"
	"github.com/mjmorales/funpack/mcp/internal/mcperr"
)

// Binary is a resolved funpack executable plus the version metadata read from
// `funpack version --json`. Path is the absolute or PATH-resolved executable;
// Version is the decoded contract.VersionInfo the preflight gates on.
type Binary struct {
	Path    string
	Version contract.VersionInfo
}

// ErrNotFound is the sentinel returned when no funpack binary can be located —
// neither $FUNPACK_BIN nor a `funpack` on PATH. It is an *mcperr.Error of
// CategoryResolver. Match it by errors.Is for the category, or by identity
// (err == ErrNotFound) when a caller must distinguish it from other resolver
// failures, since mcperr.(*Error).Is compares by category alone.
var ErrNotFound = mcperr.New(mcperr.CategoryResolver, "funpack binary not found: set $FUNPACK_BIN or put funpack on PATH")

// Resolve locates the funpack binary and populates its version metadata.
//
// Lookup order: $FUNPACK_BIN first (must exist and be an executable file), then
// exec.LookPath("funpack"), then the standard install locations (commonFunpackPaths)
// for the minimal-child-PATH case. A miss everywhere returns ErrNotFound. Once
// located, it runs `<bin> version --json` and decodes stdout into
// contract.VersionInfo; a probe failure (e.g. a funpack too old to support --json)
// or unparseable JSON returns a wrapped CategoryResolver error naming the path and
// the fix — NOT ErrNotFound, since the binary was found.
func Resolve() (Binary, error) {
	path, err := locate()
	if err != nil {
		return Binary{}, err
	}

	info, err := readVersion(path)
	if err != nil {
		return Binary{}, err
	}

	return Binary{Path: path, Version: info}, nil
}

// locate returns the funpack executable path: $FUNPACK_BIN, then PATH, then the
// common install locations (the fallback for a child process with a minimal PATH).
func locate() (string, error) {
	if bin := os.Getenv("FUNPACK_BIN"); bin != "" {
		if err := assertExecutable(bin); err != nil {
			return "", err
		}
		return bin, nil
	}

	if path, err := exec.LookPath("funpack"); err == nil {
		return path, nil
	}

	// The MCP child is frequently spawned with a minimal PATH — a GUI-launched
	// Claude Code does not inherit the login shell's PATH, so a `brew install`ed
	// funpack on /opt/homebrew/bin is invisible to LookPath here even though the
	// interactive shell resolves it. Probe the standard install locations before
	// giving up, so the common case works without the operator pinning $FUNPACK_BIN.
	for _, cand := range commonFunpackPaths() {
		if assertExecutable(cand) == nil {
			return cand, nil
		}
	}
	return "", ErrNotFound
}

// commonFunpackPaths are the standard install locations probed when funpack is not
// on the (often minimal) child PATH: Homebrew on Apple silicon and Intel, then the
// per-user ~/.local/bin the funpack:mcp install flow targets. A package var so a
// test can stub the probe set — otherwise the hardcoded locations would find a real
// funpack on the test host and defeat the not-found path.
var commonFunpackPaths = func() []string {
	paths := []string{"/opt/homebrew/bin/funpack", "/usr/local/bin/funpack"}
	if home, err := os.UserHomeDir(); err == nil {
		paths = append(paths, filepath.Join(home, ".local", "bin", "funpack"))
	}
	return paths
}

// assertExecutable verifies path names an existing, non-directory, executable
// file. A missing path is ErrNotFound; a present-but-not-executable path is a
// distinct resolver error naming the offending path.
func assertExecutable(path string) error {
	fi, err := os.Stat(path)
	if err != nil {
		return ErrNotFound
	}
	if fi.IsDir() {
		e := mcperr.New(mcperr.CategoryResolver, "FUNPACK_BIN is a directory, not an executable")
		e.Detail = path
		return e
	}
	if fi.Mode().Perm()&0o111 == 0 {
		e := mcperr.New(mcperr.CategoryResolver, "FUNPACK_BIN is not executable")
		e.Detail = path
		return e
	}
	return nil
}

// readVersion runs `<path> version --json` and decodes stdout into VersionInfo.
func readVersion(path string) (contract.VersionInfo, error) {
	cmd := exec.Command(path, contract.VersionArgv...)
	out, err := cmd.Output()
	if err != nil {
		// A located-but-failing probe is NOT "binary not found": the most common
		// cause is a funpack older than v0.7.0, which is when `version --json` was
		// added — funpack-mcp consumes that JSON by contract and never scrapes the
		// human `version` text (ADR 2026-06-15-funpack-api-contract-dual-codegen), so
		// it requires a funpack new enough to emit it. Name the path + the fix so the
		// operator does not chase a phantom path problem.
		e := mcperr.Wrap(mcperr.CategoryResolver,
			fmt.Sprintf("funpack at %s failed `funpack %s` — it is likely older than v0.7.0 (which added `version --json`); funpack-mcp requires funpack >= v0.7.0, so upgrade funpack (the v0.7.0 release tarball, a repo build, or `brew upgrade funpack` once the tap publishes 0.7.0) and point $FUNPACK_BIN at it",
				path, joinArgv(contract.VersionArgv)),
			err)
		if ee, ok := err.(*exec.ExitError); ok && len(ee.Stderr) > 0 {
			e.Detail = truncate(strings.TrimSpace(string(ee.Stderr)), 200)
		}
		return contract.VersionInfo{}, e
	}

	var info contract.VersionInfo
	if err := json.Unmarshal(out, &info); err != nil {
		e := mcperr.Wrap(mcperr.CategoryResolver, "decoding funpack version --json failed", err)
		e.Detail = truncate(string(out), 200)
		return contract.VersionInfo{}, e
	}
	return info, nil
}

// Preflight gates a resolved Binary against contract.Supported.
//
// For every schema PRESENT in b.Version.Schemas with an entry in
// contract.Supported, the version must fall inside the supported range; the
// first out-of-range schema returns a CategoryResolver error naming the schema
// and its got/want. An ABSENT schema never refuses — a build that does not yet
// emit a given schema key (e.g. introspect, which `version --json` does not yet
// carry) simply is not gated. A PRESENT schema with NO Supported entry is
// ACCEPTED (forward-compatible): the compat policy gates only the schemas it
// declares, so a future funpack that introduces a new schema key the MCP build
// has never heard of does not hard-fail this build.
func Preflight(b Binary) error {
	for key, got := range b.Version.Schemas {
		want, declared := contract.Supported[key]
		if !declared {
			// Forward-compatible: a schema this build does not gate is accepted.
			continue
		}
		if !want.Contains(got) {
			e := mcperr.New(mcperr.CategoryResolver,
				fmt.Sprintf("funpack %q schema is outside the supported range", key))
			e.Detail = fmt.Sprintf("got %d, want [%d,%d]", got, want.Min, want.Max)
			return e
		}
	}
	return nil
}

// ResolveAndPreflight resolves the binary and runs the version preflight,
// returning the resolved Binary only when both succeed.
func ResolveAndPreflight() (Binary, error) {
	b, err := Resolve()
	if err != nil {
		return Binary{}, err
	}
	if err := Preflight(b); err != nil {
		return Binary{}, err
	}
	return b, nil
}

// joinArgv renders argv for an error message ("version --json").
func joinArgv(argv []string) string {
	out := ""
	for i, a := range argv {
		if i > 0 {
			out += " "
		}
		out += a
	}
	return out
}

// truncate caps s at n runes, appending an ellipsis when it was cut, so a noisy
// stdout payload in an error Detail stays bounded.
func truncate(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n]) + "…"
}
