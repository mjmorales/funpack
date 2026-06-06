package main

import (
	"os"
	"os/exec"
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
// repo root, NOT this worktree, which lives nested under .claude/worktrees/) —
// and t.Skip's loudly, naming the resolved-but-missing path, when the tree is
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
// primary repo checkout. The primary checkout is derived from git's common
// directory so this resolves correctly from a nested worktree (where the cwd's
// own parent chain is NOT a sibling of funpack-spec); when git resolution is
// unavailable it falls back to the sibling of the binary-discovery repo root.
func resolveSpecRoot(t *testing.T) string {
	t.Helper()

	if override, ok := os.LookupEnv(SpecDirEnv); ok && override != "" {
		return override
	}

	primaryRoot, err := primaryRepoRoot()
	if err != nil {
		// No git context: fall back to the sibling of the binary-discovery root.
		primaryRoot = repoRootForBinary(t)
	}
	return filepath.Join(filepath.Dir(primaryRoot), "funpack-spec")
}

// primaryRepoRoot returns the primary (non-worktree) checkout root, derived from
// git's common directory so it is stable whether the test runs from the main
// checkout or a linked worktree nested under it. `git rev-parse --git-common-dir`
// yields the primary `.git` directory; its parent is the primary checkout root.
func primaryRepoRoot() (string, error) {
	out, err := exec.Command("git", "rev-parse", "--git-common-dir").Output()
	if err != nil {
		return "", err
	}
	commonDir, err := filepath.Abs(strings.TrimSpace(string(out)))
	if err != nil {
		return "", err
	}
	return filepath.Dir(commonDir), nil
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
