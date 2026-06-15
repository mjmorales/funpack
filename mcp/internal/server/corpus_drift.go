package server

import (
	"strings"

	"github.com/mjmorales/funpack/mcp/internal/docs"
	"github.com/mjmorales/funpack/mcp/internal/funpack"
)

// resolveCompilerVersion is the funpack-resolution seam the corpus-drift check
// reads, indirected through a package var so a test can drive the compiler
// version without execing a real funpack. It returns the resolved version and
// true, or "" and false when no funpack can be located/probed — in which case
// drift is simply not reported (there is nothing to compare against).
var resolveCompilerVersion = func() (string, bool) {
	b, err := funpack.Resolve()
	if err != nil {
		return "", false
	}
	return b.Version.Version, true
}

// CorpusDrift reports a version skew between the embedded docs corpus and the
// funpack compiler the server resolves. When Drift is true the corpus describes a
// DIFFERENT toolchain than the one that compiles, so any compiler surface change
// since CorpusVersion is invisible to docs_search — a silent lag that already
// caused a wrong field diagnosis (a helper unexported in a newer funpack still
// read as exported by the stale corpus). The whole point is to make that loud.
type CorpusDrift struct {
	// Drift is true when the corpus funpack version and the resolved compiler
	// version differ. False when they match OR when no compiler could be resolved
	// (nothing to compare).
	Drift bool `json:"drift" jsonschema:"true when the docs corpus was built against a different funpack version than the compiler this server resolves"`
	// CorpusVersion is the funpack version the corpus was generated against
	// (normalized semver, e.g. 0.6.1), from the manifest.
	CorpusVersion string `json:"corpus_version,omitempty" jsonschema:"funpack version the docs corpus was generated against"`
	// CompilerVersion is the resolved funpack version (normalized semver), or
	// empty when no funpack could be resolved.
	CompilerVersion string `json:"compiler_version,omitempty" jsonschema:"funpack version this server resolved, empty when none was found"`
	// Warning is a human-readable drift message, set only when Drift is true, so a
	// model reading the tool output sees the lag spelled out rather than having to
	// diff two version fields itself.
	Warning string `json:"warning,omitempty" jsonschema:"human-readable drift warning, set only when drift is true"`
}

// detectCorpusDrift compares the manifest's funpack version against the resolved
// compiler version (via the resolveCompilerVersion seam) and builds a CorpusDrift.
// A missing/unresolvable compiler yields Drift=false with an empty CompilerVersion
// — drift cannot be asserted without both sides, so it is reported as "no drift"
// rather than a false alarm. Both version strings are normalized (the `funpack `
// prefix on the manifest stamp is stripped) before the equality test.
func detectCorpusDrift(m *docs.Manifest) CorpusDrift {
	corpusVer := normalizeFunpackVersion(m.FunpackVersion)

	compilerVer, ok := resolveCompilerVersion()
	if !ok {
		return CorpusDrift{Drift: false, CorpusVersion: corpusVer}
	}
	compilerVer = normalizeFunpackVersion(compilerVer)

	if corpusVer == compilerVer {
		return CorpusDrift{Drift: false, CorpusVersion: corpusVer, CompilerVersion: compilerVer}
	}
	return CorpusDrift{
		Drift:           true,
		CorpusVersion:   corpusVer,
		CompilerVersion: compilerVer,
		Warning: "docs corpus is funpack " + corpusVer + " but the resolved compiler is funpack " +
			compilerVer + " — docs_search may describe an older toolchain than the one that compiles; regenerate the corpus (task docs-regen) against the installed funpack",
	}
}

// normalizeFunpackVersion strips a leading `funpack ` prefix and surrounding
// whitespace so a manifest stamp ("funpack 0.6.1") and a `version --json` field
// ("0.7.0") compare on the same bare-semver footing.
func normalizeFunpackVersion(s string) string {
	s = strings.TrimSpace(s)
	s = strings.TrimPrefix(s, "funpack ")
	return strings.TrimSpace(s)
}
