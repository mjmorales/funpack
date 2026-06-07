package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Index Contract end-to-end round-trip: this is the ONE test that exercises the
// real §29 coupling — the actual funpack binary spawned over a process boundary
// against a real §14 example tree — rather than a synthetic stub. It composes
// the four wave-1/2 seams in their production order:
//
//	DiscoverFunpack → InvokeBuild → ClassifyResult → ReadIndex
//
// and asserts the live result: exit 0 classifies to Success and the derived
// .funpack/index.ndjson reads back as a non-empty byte stream.
//
// TWO environment dependencies are isolated to THIS test so the unit suites stay
// green anywhere: (1) the example trees live in the SIBLING funpack-spec repo,
// not inside funpack, and (2) the funpack binary is a gitignored derived product
// (built via `task funpack:binary`). Both are resolved deterministically — never
// hardcoded — and a clean t.Skip (never a failure) covers either being absent.

// SpecDirEnv is the explicit-override variable for the funpack-spec checkout
// root. When set, it short-circuits the conventional-sibling resolution — the
// seam an operator or CI uses to point the integration test at a spec checkout
// that does not sit at the conventional sibling path.
const SpecDirEnv = "FUNPACK_SPEC_DIR"

// pongExampleRelPath is the §14 example tree this round-trip drives, relative to
// the resolved funpack-spec root. pong is confirmed to build clean (exit 0) and
// emit both products, making it the canonical real-tree fixture for the live
// coupling.
var pongExampleRelPath = filepath.Join("examples", "pong")

func TestIntegrationBuildClassifyReadRoundTrip(t *testing.T) {
	pongTree := resolvePongTree(t)
	binary := resolveFunpackBinary(t)

	// Build against a COPY in a temp dir, never the sibling checkout: funpack
	// writes its derived .funpack/ under the tree it builds, so building in place
	// would mutate the read-only spec repo. The copy (auto-removed by t.TempDir)
	// leaves the sibling checkout byte-for-byte unmodified after the run.
	treeCopy := copyTree(t, pongTree)

	result, err := InvokeBuild(binary, treeCopy)
	if err != nil {
		t.Fatalf("funpack build spawn failed against %s: %v", treeCopy, err)
	}

	outcome, err := ClassifyResult(result)
	if err != nil {
		t.Fatalf("classify failed (exit %d, stderr=%q): %v", result.ExitCode, string(result.Stderr), err)
	}
	if outcome != Success {
		t.Fatalf("outcome = %v, want Success (exit %d, stderr=%q)", outcome, result.ExitCode, string(result.Stderr))
	}

	indexBytes, err := ReadIndex(treeCopy)
	if err != nil {
		t.Fatalf("read-back of the index product failed: %v", err)
	}
	if len(indexBytes) == 0 {
		t.Fatal("a Success build must leave a non-empty index.ndjson, got 0 bytes")
	}
}

// resolvePongTree resolves the pong example tree under the funpack-spec checkout
// by fixed precedence — FUNPACK_SPEC_DIR override, then the conventional sibling
// of the MAIN checkout (worktree-aware: the sibling is anchored on the primary
// checkout root, NOT this worktree nested under .claude/worktrees/) — and
// t.Skip's loudly, naming the resolved-but-missing path, when the tree is
// absent. Absence is never a failure: the unit suites must pass in an
// environment with no spec checkout.
func resolvePongTree(t *testing.T) string {
	t.Helper()

	specRoot := resolveSpecRoot(t)
	pongTree := filepath.Join(specRoot, pongExampleRelPath)
	if _, err := os.Stat(filepath.Join(pongTree, "funpack_configs")); err != nil {
		t.Skipf(
			"skipping integration round-trip: pong example tree not found at %s "+
				"(set %s to a funpack-spec checkout, or place one at the conventional sibling path): %v",
			pongTree, SpecDirEnv, err,
		)
	}
	return pongTree
}

// resolveSpecRoot resolves the funpack-spec checkout root: the FUNPACK_SPEC_DIR
// override wins; otherwise the conventional sibling `funpack-spec` of the
// PRIMARY (main) checkout. `go test` runs with the cwd pinned to this package
// dir (warden/), so the repo root is its parent — but inside an orchestrator
// task worktree that parent lives under <main>/.claude/worktrees/<...>/, whose
// sibling is NOT funpack-spec. primaryCheckoutRoot strips that infix so the
// sibling anchors on the real checkout. This mirrors funpack/golden_test.odin's
// resolve_spec_dir/main_checkout_root convention (no git dependency: resolution
// is a pure path transform, deterministic and offline).
func resolveSpecRoot(t *testing.T) string {
	t.Helper()

	if override, ok := os.LookupEnv(SpecDirEnv); ok && override != "" {
		return override
	}

	return filepath.Join(filepath.Dir(primaryCheckoutRoot(repoRootForBinary(t))), "funpack-spec")
}

// primaryCheckoutRoot maps an orchestrator task-worktree repo root onto the main
// checkout root: a root containing the `/.claude/worktrees/` infix is truncated
// at that segment (yielding the directory that holds .claude — the real repo,
// whose siblings exist on disk); any other root is already the main checkout and
// is returned unchanged. This is the Go mirror of golden_test.odin's
// main_checkout_root — it guarantees the conventional `../funpack-spec` sibling
// resolves to the real checkout's sibling, never <main>/.claude/worktrees/funpack-spec.
func primaryCheckoutRoot(root string) string {
	marker := string(filepath.Separator) + ".claude" + string(filepath.Separator) + "worktrees" + string(filepath.Separator)
	if idx := strings.Index(root, marker); idx >= 0 {
		return root[:idx]
	}
	return root
}

// TestPrimaryCheckoutRootStripsWorktreeInfix pins spec-sibling resolution for
// BOTH context shapes the integration test runs from, mirroring the Odin side's
// test_main_checkout_root_strips_worktree_infix. The main-checkout case is the
// one the prior git-derived resolver got wrong (a relative --git-common-dir
// anchored on the test cwd, silently SKIPping the round-trip from the main
// checkout); the worktree case is the one that masked it.
func TestPrimaryCheckoutRootStripsWorktreeInfix(t *testing.T) {
	main := filepath.Join("/repos", "funpack")

	// A repo root inside an orchestrator task worktree anchors at the main
	// checkout, so the ../funpack-spec sibling resolves to the real sibling
	// rather than <main>/.claude/worktrees/funpack-spec (which never exists).
	worktree := filepath.Join(main, ".claude", "worktrees", "slug-task-3")
	if got := primaryCheckoutRoot(worktree); got != main {
		t.Errorf("worktree root: primaryCheckoutRoot(%q) = %q, want %q", worktree, got, main)
	}

	// A main-checkout root has no infix and is returned unchanged — this is the
	// shape `go test` runs under from the primary checkout (cwd parent = repo root).
	if got := primaryCheckoutRoot(main); got != main {
		t.Errorf("main-checkout root: primaryCheckoutRoot(%q) = %q, want %q", main, got, main)
	}

	// A .claude path WITHOUT the /worktrees/ segment is not the infix and must
	// not be truncated.
	settings := filepath.Join(main, ".claude", "settings")
	if got := primaryCheckoutRoot(settings); got != settings {
		t.Errorf("non-worktree .claude path: primaryCheckoutRoot(%q) = %q, want %q", settings, got, settings)
	}
}

// repoRootForBinary resolves the repo root the freshly-built funpack binary sits
// under: the parent of the warden/ package directory the test runs from. The
// acceptance flow builds the binary into THIS tree (`task funpack:binary` →
// <root>/funpack/funpack), so binary discovery must anchor on the cwd's parent,
// not the primary checkout.
func repoRootForBinary(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs("..")
	if err != nil {
		t.Fatalf("resolve repo root from warden cwd: %v", err)
	}
	return root
}

// resolveFunpackBinary discovers the funpack binary through warden's production
// discovery seam — FUNPACK_BIN override, then the in-repo build, then PATH — with
// the repo root anchored on this tree so the `task funpack:binary` product is
// found. It t.Skip's loudly when no binary resolves, naming the in-repo path the
// build verb would have produced, so the unit suites pass without a built binary.
func resolveFunpackBinary(t *testing.T) string {
	t.Helper()

	root := repoRootForBinary(t)
	binary, err := Discovery{RepoRoot: root}.DiscoverFunpack()
	if err != nil {
		t.Skipf(
			"skipping integration round-trip: no funpack binary found "+
				"(build it with `task funpack:binary` to emit %s, or set %s): %v",
			filepath.Join(root, repoBinaryRelPath), FunpackBinEnv, err,
		)
	}
	return binary
}

// copyTree recursively copies src into a fresh temp dir and returns the copy
// root. It is the hygiene seam that keeps the build off the read-only sibling
// checkout: the build mutates only the copy (which t.TempDir removes at the end
// of the test), so funpack-spec is left untouched.
//
// Assumes the §14 example trees contain only directories and regular files (no
// symlinks): a symlink would be copied as its target's bytes via ReadFile, not
// re-created as a link. The spec's example trees hold none, so this is sound.
func copyTree(t *testing.T, src string) string {
	t.Helper()

	dst := filepath.Join(t.TempDir(), filepath.Base(src))
	err := filepath.WalkDir(src, func(path string, d os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		target := filepath.Join(dst, rel)
		if d.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		return os.WriteFile(target, data, 0o644)
	})
	if err != nil {
		t.Fatalf("copy example tree %s -> %s: %v", src, dst, err)
	}
	return dst
}
