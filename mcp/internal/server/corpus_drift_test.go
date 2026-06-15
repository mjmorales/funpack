package server

import (
	"testing"

	"github.com/mjmorales/funpack/mcp/internal/docs"
)

// withCompilerVersion swaps the resolveCompilerVersion seam for the duration of a
// test, restoring it after. ok=false models a funpack that could not be resolved.
func withCompilerVersion(t *testing.T, version string, ok bool) {
	t.Helper()
	orig := resolveCompilerVersion
	resolveCompilerVersion = func() (string, bool) { return version, ok }
	t.Cleanup(func() { resolveCompilerVersion = orig })
}

// TestDetectCorpusDriftFlagsSkew is the F8 guard: a corpus generated against an
// older funpack than the resolved compiler must report drift loudly — the field a
// model reads to know docs_search describes a stale toolchain. Mirrors the field
// bug: corpus funpack 0.6.1, compiler funpack 0.7.0.
func TestDetectCorpusDriftFlagsSkew(t *testing.T) {
	withCompilerVersion(t, "0.7.0", true)
	m := &docs.Manifest{FunpackVersion: "funpack 0.6.1"}

	d := detectCorpusDrift(m)
	if !d.Drift {
		t.Fatal("expected drift between corpus 0.6.1 and compiler 0.7.0")
	}
	if d.CorpusVersion != "0.6.1" {
		t.Errorf("CorpusVersion = %q, want 0.6.1 (funpack prefix must be stripped)", d.CorpusVersion)
	}
	if d.CompilerVersion != "0.7.0" {
		t.Errorf("CompilerVersion = %q, want 0.7.0", d.CompilerVersion)
	}
	if d.Warning == "" {
		t.Error("drift must carry a human-readable warning")
	}
}

// TestDetectCorpusDriftNoSkewWhenEqual proves a corpus matching the compiler
// reports no drift, even across the `funpack ` prefix asymmetry (manifest stamps
// "funpack 0.7.0", `version --json` yields "0.7.0").
func TestDetectCorpusDriftNoSkewWhenEqual(t *testing.T) {
	withCompilerVersion(t, "0.7.0", true)
	m := &docs.Manifest{FunpackVersion: "funpack 0.7.0"}

	d := detectCorpusDrift(m)
	if d.Drift {
		t.Fatalf("reported drift on equal versions: corpus=%q compiler=%q", d.CorpusVersion, d.CompilerVersion)
	}
	if d.Warning != "" {
		t.Errorf("no-drift result must carry no warning, got %q", d.Warning)
	}
}

// TestDetectCorpusDriftNoCompilerIsNotDrift proves an unresolvable compiler is
// reported as no-drift (nothing to compare), never a false alarm: drift requires
// both sides. The corpus version is still echoed so a caller can see it.
func TestDetectCorpusDriftNoCompilerIsNotDrift(t *testing.T) {
	withCompilerVersion(t, "", false)
	m := &docs.Manifest{FunpackVersion: "funpack 0.6.1"}

	d := detectCorpusDrift(m)
	if d.Drift {
		t.Fatal("reported drift with no resolvable compiler — cannot assert drift without both sides")
	}
	if d.CompilerVersion != "" {
		t.Errorf("CompilerVersion = %q, want empty when no funpack resolved", d.CompilerVersion)
	}
	if d.CorpusVersion != "0.6.1" {
		t.Errorf("CorpusVersion = %q, want 0.6.1 (still echoed)", d.CorpusVersion)
	}
}

// TestNormalizeFunpackVersion pins the prefix/whitespace stripping the equality
// test relies on, so the manifest stamp and the version --json field compare on
// the same footing.
func TestNormalizeFunpackVersion(t *testing.T) {
	cases := map[string]string{
		"funpack 0.6.1":     "0.6.1",
		"0.7.0":             "0.7.0",
		"  funpack 0.7.0  ": "0.7.0",
		"funpack 0.7.0-rc1": "0.7.0-rc1",
	}
	for in, want := range cases {
		if got := normalizeFunpackVersion(in); got != want {
			t.Errorf("normalizeFunpackVersion(%q) = %q, want %q", in, got, want)
		}
	}
}
