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
// Lookup order: $FUNPACK_BIN first (must exist and be an executable file),
// otherwise exec.LookPath("funpack"). A miss in both returns ErrNotFound. Once
// located, it runs `<bin> version --json` and decodes stdout into
// contract.VersionInfo; a non-zero exit or unparseable JSON returns a wrapped
// CategoryResolver error.
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

// locate returns the funpack executable path, honoring $FUNPACK_BIN before PATH.
func locate() (string, error) {
	if bin := os.Getenv("FUNPACK_BIN"); bin != "" {
		if err := assertExecutable(bin); err != nil {
			return "", err
		}
		return bin, nil
	}

	path, err := exec.LookPath("funpack")
	if err != nil {
		return "", ErrNotFound
	}
	return path, nil
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
		return contract.VersionInfo{}, mcperr.Wrap(mcperr.CategoryResolver,
			fmt.Sprintf("running `funpack %s` failed", joinArgv(contract.VersionArgv)), err)
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
