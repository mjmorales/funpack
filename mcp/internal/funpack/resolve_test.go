package funpack

import (
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/mjmorales/funpack/mcp/internal/contract"
	"github.com/mjmorales/funpack/mcp/internal/mcperr"
)

// writeFakeFunpack writes an executable shell script named "funpack" into dir
// that, on `version --json`, prints payload verbatim and exits 0. Any other argv
// exits non-zero, mirroring how the real binary would reject an unknown verb.
// It is skipped on Windows, where the script shebang does not apply.
func writeFakeFunpack(t *testing.T, dir, payload string) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("fake shell-script funpack is POSIX-only")
	}
	path := filepath.Join(dir, "funpack")
	script := "#!/bin/sh\n" +
		"if [ \"$1\" = \"version\" ] && [ \"$2\" = \"--json\" ]; then\n" +
		"  printf '%s' '" + payload + "'\n" +
		"  exit 0\n" +
		"fi\n" +
		"exit 3\n"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake funpack: %v", err)
	}
	return path
}

// isolatePATH clears any ambient funpack from PATH and FUNPACK_BIN so each test
// resolves only what it explicitly stages.
func isolatePATH(t *testing.T) {
	t.Helper()
	t.Setenv("PATH", "")
	t.Setenv("FUNPACK_BIN", "")
	// Neutralize the hardcoded common-location probe too, else a real funpack on
	// /opt/homebrew/bin leaks into the "no binary available" tests.
	orig := commonFunpackPaths
	commonFunpackPaths = func() []string { return nil }
	t.Cleanup(func() { commonFunpackPaths = orig })
}

const goodPayload = `{"version":"0.6.2","schemas":{"artifact":18,"index":6}}`

// TestResolveFromFunpackBin proves $FUNPACK_BIN takes precedence and its
// `version --json` stdout decodes into contract.VersionInfo.
func TestResolveFromFunpackBin(t *testing.T) {
	dir := t.TempDir()
	bin := writeFakeFunpack(t, dir, goodPayload)
	isolatePATH(t)
	t.Setenv("FUNPACK_BIN", bin)

	b, err := Resolve()
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if b.Path != bin {
		t.Fatalf("Path = %q, want %q", b.Path, bin)
	}
	if b.Version.Version != "0.6.2" {
		t.Fatalf("Version = %q, want 0.6.2", b.Version.Version)
	}
	if got := b.Version.Schemas[contract.SchemaArtifact]; got != 18 {
		t.Fatalf("artifact schema = %d, want 18", got)
	}
	if got := b.Version.Schemas[contract.SchemaIndex]; got != 6 {
		t.Fatalf("index schema = %d, want 6", got)
	}
}

// TestResolveFromPATH proves the PATH fallback when $FUNPACK_BIN is unset.
func TestResolveFromPATH(t *testing.T) {
	dir := t.TempDir()
	writeFakeFunpack(t, dir, goodPayload)
	isolatePATH(t)
	t.Setenv("PATH", dir)

	b, err := Resolve()
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if b.Path != filepath.Join(dir, "funpack") {
		t.Fatalf("Path = %q, want %q", b.Path, filepath.Join(dir, "funpack"))
	}
	if b.Version.Version != "0.6.2" {
		t.Fatalf("Version = %q, want 0.6.2", b.Version.Version)
	}
}

// TestResolveMissingIsErrNotFound proves a clean environment (no FUNPACK_BIN, no
// funpack on PATH) returns ErrNotFound as a CategoryResolver mcperr.Error.
func TestResolveMissingIsErrNotFound(t *testing.T) {
	isolatePATH(t)

	_, err := Resolve()
	if err == nil {
		t.Fatal("Resolve succeeded with no binary available")
	}
	if err != ErrNotFound {
		t.Fatalf("err = %v, want identity ErrNotFound", err)
	}
	if !errors.Is(err, mcperr.New(mcperr.CategoryResolver, "")) {
		t.Fatalf("err category is not resolver: %v", err)
	}
}

// TestResolveFunpackBinMissingIsErrNotFound proves a pointed-but-absent
// $FUNPACK_BIN is also ErrNotFound, not a generic stat error.
func TestResolveFunpackBinMissingIsErrNotFound(t *testing.T) {
	isolatePATH(t)
	t.Setenv("FUNPACK_BIN", filepath.Join(t.TempDir(), "nope"))

	if _, err := Resolve(); err != ErrNotFound {
		t.Fatalf("err = %v, want ErrNotFound", err)
	}
}

// TestResolveUnparseableJSONIsResolverError proves a binary that emits
// non-JSON on `version --json` fails with a wrapped CategoryResolver error
// (never a silent best-effort parse of human text).
func TestResolveUnparseableJSONIsResolverError(t *testing.T) {
	dir := t.TempDir()
	bin := writeFakeFunpack(t, dir, "funpack version 0.6.2 (not json)")
	isolatePATH(t)
	t.Setenv("FUNPACK_BIN", bin)

	_, err := Resolve()
	if err == nil {
		t.Fatal("Resolve succeeded on non-JSON version output")
	}
	if !errors.Is(err, mcperr.New(mcperr.CategoryResolver, "")) {
		t.Fatalf("err category is not resolver: %v", err)
	}
}

// TestPreflightPassesOnSupported proves the canonical {artifact:18,index:6}
// payload clears Preflight.
func TestPreflightPassesOnSupported(t *testing.T) {
	b := Binary{Version: contract.VersionInfo{
		Version: "0.6.2",
		Schemas: map[string]int{contract.SchemaArtifact: 18, contract.SchemaIndex: 6},
	}}
	if err := Preflight(b); err != nil {
		t.Fatalf("Preflight refused a supported payload: %v", err)
	}
}

// TestPreflightRefusesBumpedSchema proves a present schema outside its range is
// refused with a CategoryResolver error naming the schema and got/want.
func TestPreflightRefusesBumpedSchema(t *testing.T) {
	b := Binary{Version: contract.VersionInfo{
		Version: "0.7.0",
		Schemas: map[string]int{contract.SchemaArtifact: 19, contract.SchemaIndex: 6},
	}}
	err := Preflight(b)
	if err == nil {
		t.Fatal("Preflight accepted artifact schema 19 (supported max 18)")
	}
	var de *mcperr.Error
	if !errors.As(err, &de) || de.Code != mcperr.CategoryResolver {
		t.Fatalf("err is not a CategoryResolver mcperr.Error: %v", err)
	}
	if de.Detail != "got 19, want [18,18]" {
		t.Fatalf("Detail = %q, want %q", de.Detail, "got 19, want [18,18]")
	}
}

// TestPreflightAbsentIntrospectDoesNotRefuse proves an absent schema key never
// refuses: today's `version --json` carries no introspect key, and Preflight
// must not demand one.
func TestPreflightAbsentIntrospectDoesNotRefuse(t *testing.T) {
	b := Binary{Version: contract.VersionInfo{
		Version: "0.6.2",
		Schemas: map[string]int{contract.SchemaArtifact: 18, contract.SchemaIndex: 6},
	}}
	if _, declared := contract.Supported[contract.SchemaIntrospect]; !declared {
		t.Fatal("test premise broken: introspect should have a Supported entry")
	}
	if _, present := b.Version.Schemas[contract.SchemaIntrospect]; present {
		t.Fatal("test premise broken: payload should omit introspect")
	}
	if err := Preflight(b); err != nil {
		t.Fatalf("Preflight refused on absent introspect: %v", err)
	}
}

// TestPreflightUnknownSchemaIsForwardCompatible proves a present schema with no
// Supported entry is accepted, so a future funpack key never hard-fails this
// build.
func TestPreflightUnknownSchemaIsForwardCompatible(t *testing.T) {
	b := Binary{Version: contract.VersionInfo{
		Version: "0.9.0",
		Schemas: map[string]int{contract.SchemaArtifact: 18, "future_schema": 42},
	}}
	if err := Preflight(b); err != nil {
		t.Fatalf("Preflight refused an unknown forward-compatible schema: %v", err)
	}
}

// TestResolveAndPreflight proves the convenience composes resolve then preflight
// against a fake binary emitting the canonical supported payload.
func TestResolveAndPreflight(t *testing.T) {
	dir := t.TempDir()
	bin := writeFakeFunpack(t, dir, goodPayload)
	isolatePATH(t)
	t.Setenv("FUNPACK_BIN", bin)

	b, err := ResolveAndPreflight()
	if err != nil {
		t.Fatalf("ResolveAndPreflight: %v", err)
	}
	if b.Path != bin {
		t.Fatalf("Path = %q, want %q", b.Path, bin)
	}
}

// TestResolveAndPreflightRefusesBumped proves the convenience surfaces a
// preflight refusal: a fake binary reporting artifact 19 fails the composed call.
func TestResolveAndPreflightRefusesBumped(t *testing.T) {
	dir := t.TempDir()
	bin := writeFakeFunpack(t, dir, `{"version":"0.7.0","schemas":{"artifact":19,"index":6}}`)
	isolatePATH(t)
	t.Setenv("FUNPACK_BIN", bin)

	if _, err := ResolveAndPreflight(); err == nil {
		t.Fatal("ResolveAndPreflight accepted a bumped artifact schema")
	}
}
