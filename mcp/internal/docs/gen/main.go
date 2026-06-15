// Command gen regenerates the committed funpack documentation corpus.
//
// Invoked as `go run ./internal/docs/gen` (wired to `task docs-regen`). It is a
// thin filesystem wrapper around internal/docs/gen/gencore: gencore.Generate
// runs the three extractors (funpack-spec prose, the engine.* signature files,
// the funpack plugin's authoring skills) and returns the corpus in memory; this
// command persists it as per-kind JSON shards under internal/docs/corpus/ plus
// internal/docs/manifest.json. Those files are committed; the docs package
// embeds them so the binary never reads the spec at runtime. The corpus pin
// check (internal/docs/corpus_pin_test.go) imports the same gencore, so drift
// detection and generation share one extraction path.
//
// Source resolution: the spec lives in a sibling repo, resolved from
// FUNPACK_SPEC_DIR (default <module-root>/../funpack-spec). The plugin skills
// live in the funpack repo at <repo-root>/plugins/funpack.
package main

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/mjmorales/funpack/mcp/internal/docs/gen/gencore"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "docs-regen: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	// `go run ./internal/docs/gen` runs from the module root (mcp/).
	moduleRoot, err := os.Getwd()
	if err != nil {
		return err
	}
	outDir := filepath.Join(moduleRoot, "internal", "docs")

	r, err := gencore.ResolveRoots(moduleRoot)
	if err != nil {
		return err
	}
	res, err := gencore.Generate(r)
	if err != nil {
		return err
	}

	corpusDir := filepath.Join(outDir, "corpus")
	if err := os.MkdirAll(corpusDir, 0o755); err != nil {
		return fmt.Errorf("mkdir corpus: %w", err)
	}
	if err := gencore.WriteShard(corpusDir, "spec.json", res.Spec); err != nil {
		return err
	}
	if err := gencore.WriteShard(corpusDir, "engine.json", res.Engine); err != nil {
		return err
	}
	if err := gencore.WriteShard(corpusDir, "plugin.json", res.Plugin); err != nil {
		return err
	}
	if err := gencore.WriteJSON(filepath.Join(outDir, "manifest.json"), res.Manifest); err != nil {
		return err
	}

	fmt.Fprintf(os.Stderr, "docs-regen: spec=%d engine=%d plugin=%d (spec ref %s, %s)\n",
		len(res.Spec), len(res.Engine), len(res.Plugin), res.Manifest.SpecRef, res.Manifest.FunpackVersion)
	return nil
}
