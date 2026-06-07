// Cross-example acceptance sweep: the milestone's acceptance surface. It drives
// the whole consumer spine end-to-end against the live funpack-spec golden
// corpus — invoke `funpack build` over the §29 process boundary, classify its
// exit, read back the §14 index product, and decode EVERY record through the
// exact-match schema spine — for each of the nine closed example trees. Where
// the unit tests pin each seam against synthetic input, this proves the seams
// compose against real, machine-emitted streams: the integration point where a
// drift between funpack's emission and warden's decode surfaces as a test
// failure rather than at governance time.
//
// The corpus is CLOSED and enumerated literally (arena, assets, hud, hunt,
// krognid, numerics, pong, snake, yard) so corpus drift is caught two ways: a
// name added to the spec but not here is simply never swept, and a name removed
// from the spec but still here is a hard failure when its tree is missing. A
// missing whole-corpus checkout is a LOUD skip (the runtime/compiler golden
// convention — never a silent pass); a missing INDIVIDUAL tree under a present
// checkout is a hard failure.
package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/mjmorales/funpack/warden/index"
)

// goldenCorpus is the CLOSED set of nine funpack-spec example trees the sweep
// enumerates, in the spec's example-directory order. It is a literal list, not a
// directory scan, precisely so corpus drift is caught: the sweep asserts exactly
// these names build clean and decode exact-match, so neither a silently-added
// example (never swept) nor a silently-removed one (a hard failure on its
// now-missing tree) slips through unnoticed.
var goldenCorpus = []string{
	"arena",
	"assets",
	"hud",
	"hunt",
	"krognid",
	"numerics",
	"pong",
	"snake",
	"yard",
}

func TestCrossExampleAcceptanceSweep(t *testing.T) {
	repoRoot := repoRootDir(t)
	binary := resolveFunpackBinary(t, repoRoot)

	specRoot := resolveSpecRoot(t)
	if !isDir(specRoot) {
		// Per-corpus-root LOUD skip, naming the resolved-but-missing path: the
		// whole corpus is unavailable on this machine, exactly the
		// runtime/compiler golden convention. NEVER a silent pass — and the skip
		// is at the corpus root, never per-example, so it can never mask a
		// genuinely-missing individual tree under a present checkout.
		t.Skipf(
			"SKIP cross-example sweep: funpack-spec checkout not found at %q — set %s or check out funpack-spec as a sibling of the repo",
			specRoot, SpecDirEnv,
		)
	}

	for _, example := range goldenCorpus {
		example := example
		t.Run(example, func(t *testing.T) {
			treeDir := filepath.Join(specRoot, "examples", example)
			// A missing INDIVIDUAL tree under a present checkout is corpus drift —
			// a hard FAILURE, not a skip — so a spec that drops an enumerated
			// example is caught loudly here.
			if !isDir(treeDir) {
				t.Fatalf("corpus drift: example tree %q is missing under a present spec checkout (%s)", example, treeDir)
			}
			sweepExample(t, binary, treeDir)
		})
	}
}

// sweepExample runs the full build → classify → read → decode contract against
// one example tree. funpack writes its derived `.funpack/` products under its
// cwd, and the spec checkout is read-only, so the build runs against a COPY in a
// temp dir (auto-cleaned by t.TempDir) — the spec checkout stays pristine.
func sweepExample(t *testing.T, binary, treeDir string) {
	t.Helper()
	workTree := copyTree(t, treeDir)

	result, err := InvokeBuild(binary, workTree)
	if err != nil {
		t.Fatalf("funpack build spawn failed: %v", err)
	}

	// §29 §3 exit classification. The whole corpus is well-formed (129 @gtag
	// total, zero @todo/@stub), so the contractual outcome is the clean build:
	// exit 0 → Success. A ContractViolation (exit 1 or any off-contract code) is
	// a hard failure here — the spawned binary did not honor §29 §3.
	outcome, err := ClassifyResult(result)
	if err != nil {
		t.Fatalf("build exit violates the §29 §3 contract: %v\nstdout=%q", err, string(result.Stdout))
	}
	// Failure (exit 2 — malformed tree / compile-gate / host-IO fault) is a hard
	// test failure for a well-formed corpus tree: the corpus must build clean.
	if outcome != Success {
		t.Fatalf("expected a clean build (Success) for well-formed corpus tree, got %s\nstderr=%q", outcome, string(result.Stderr))
	}

	rawIndex, err := ReadIndex(workTree)
	if err != nil {
		t.Fatalf("reading back the index product after a Success build: %v", err)
	}

	decodeEveryRecord(t, rawIndex)
}

// decodeEveryRecord runs the whole emitted stream through the exact-match decode
// spine and asserts EVERY record decodes cleanly. It decodes whatever the stream
// carries — the one-per-stream project record always, plus any per-declaration
// decl records — rather than asserting a fixed line count, so it is correct both
// before and after funpack's live decl-record emission lands: at this branch's
// base funpack emits a project record only, and the same loop covers a stream
// that later also carries decl lines. The assertion is structural-exact, not a
// presence count: zero schema-version mismatches, zero unknown record kinds,
// zero unknown fields, zero missing mandatory fields. It deliberately does NOT
// assert decl-record presence (that emission is a parallel funpack-side task).
func decodeEveryRecord(t *testing.T, raw []byte) {
	t.Helper()
	records, err := index.DecodeStream(strings.NewReader(string(raw)))
	if err != nil {
		// A DecodeStream error already covers the version-gate and unknown-kind
		// refusals (the spine fails fast on the first), so any of them surfaces
		// here with the offending line number.
		t.Fatalf("stream decode failed (version skew, unknown kind, or framing error): %v", err)
	}
	if len(records) == 0 {
		// The producer emits the one-per-stream project record on every build, so
		// an empty stream is itself a contract break.
		t.Fatalf("decoded zero records — the stream must carry at least the project record")
	}

	sawProject := false
	for i, rec := range records {
		switch rec.Kind {
		case index.RecordKindProject:
			sawProject = true
			// Full exact-match project decode: presence of every mandatory key,
			// no unknown key (strict), and the closed capability/gate-family
			// enums — any failure is a contract skew.
			if _, err := index.DecodeProjectRecord(rec); err != nil {
				t.Fatalf("record %d (project) failed exact-match decode: %v", i, err)
			}
		case index.RecordKindDecl:
			// Full exact-match decl decode: presence of every mandatory field, no
			// unknown key (strict), and the closed decl-kind enum. Present only
			// once funpack's decl emission lands; decoded the same exact-match way
			// when it does, with no presence assertion either way.
			if _, err := index.DecodeDecl(rec.Raw); err != nil {
				t.Fatalf("record %d (decl) failed exact-match decode: %v", i, err)
			}
		default:
			// DecodeStream already refuses an unknown kind, so this arm is
			// unreachable on a conforming stream — it exists so a future RecordKind
			// added without a sweep arm is a hard failure, not a silent skip.
			t.Fatalf("record %d has unhandled kind %s — the sweep must decode every closed record kind", i, rec.Kind)
		}
	}
	if !sawProject {
		t.Fatalf("stream carried no project record — the producer emits exactly one per build")
	}
}

// repoRootDir resolves this repo's root from the test's own source location: the
// `warden` package dir is one level under the repo root, so the parent of the
// directory holding this file IS the root. Deriving it from runtime.Caller keeps
// the sweep independent of the cwd `go test` runs under and machine-path-free —
// the same no-baked-in-path discipline DiscoverFunpack holds.
func repoRootDir(t *testing.T) string {
	t.Helper()
	_, thisFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot resolve this test's source path via runtime.Caller")
	}
	pkgDir := filepath.Dir(thisFile)                // <repo>/warden
	root, err := filepath.Abs(filepath.Dir(pkgDir)) // <repo>
	if err != nil {
		t.Fatalf("abs repo root: %v", err)
	}
	return root
}

// resolveFunpackBinary discovers the funpack binary the sweep spawns, anchored
// at this repo root so it resolves the conventionally-built in-repo binary
// (`<root>/funpack/funpack`) the warden test verb deps on (Taskfile: test deps
// funpack:binary, a hermetic build-from-tree). An absent binary is a hard
// failure, not a skip: under `task warden:test` the binary is always built
// first, so its absence is a real setup break, not the environment-not-present
// case the spec-root skip covers.
func resolveFunpackBinary(t *testing.T, repoRoot string) string {
	t.Helper()
	binary, err := Discovery{RepoRoot: repoRoot}.DiscoverFunpack()
	if err != nil {
		t.Fatalf("resolving funpack binary (expected the in-tree build at %s/funpack/funpack from `task warden:test`): %v", repoRoot, err)
	}
	return binary
}

// isDir reports whether path is an existing directory — the existence test the
// per-corpus-root skip and the per-example hard-failure both key on.
// (Spec-root resolution, the worktree-infix strip, and copyTree are shared with
// the integration round-trip — see integration_test.go's resolveSpecRoot,
// primaryCheckoutRoot, and copyTree.)
func isDir(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}
