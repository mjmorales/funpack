// Command gen is the dual-target code generator for the funpack <-> funpack-mcp
// API boundary. It reads the FROZEN single source of truth at
// <repo-root>/contract/funpack-api.json and emits BOTH sides of the boundary:
//
//   - the Go side (-go-out, default <root>/mcp/internal/contract/contract_gen.go),
//     a package the MCP resolver, preflight, and §28 codec/handshake/demux import; and
//   - the Odin side (-odin-out, default empty = skip), a `package funpack` file of
//     field-name + §28-name string consts the funpack-team task lands under funpack/.
//
// The contract owns SHAPE (field names, command/event taxonomy) and the MCP's
// supported version RANGES; the actual schema VALUES live in the Odin constants
// and are pinned to the contract by a read-only sync test. Run via:
//
//	go run ./internal/contract/gen                 # Go side -> default path
//	go run ./internal/contract/gen -odin-out X.odin # also emit the Odin side
//
// See ADR 2026-06-15-funpack-api-contract-dual-codegen.
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "contract gen:", err)
		os.Exit(1)
	}
}

func run() error {
	root, err := repoRoot()
	if err != nil {
		return err
	}

	defaultGoOut := filepath.Join(root, "mcp", "internal", "contract", "contract_gen.go")
	goOut := flag.String("go-out", defaultGoOut, "output path for the generated Go file (package contract)")
	odinOut := flag.String("odin-out", "", "output path for the generated Odin file (package funpack); empty = skip")
	flag.Parse()

	contractPath := filepath.Join(root, "contract", "funpack-api.json")
	c, err := loadContract(contractPath)
	if err != nil {
		return fmt.Errorf("load contract %s: %w", contractPath, err)
	}

	goSrc, err := renderGo(c)
	if err != nil {
		return fmt.Errorf("render Go: %w", err)
	}
	if err := writeFile(*goOut, goSrc); err != nil {
		return fmt.Errorf("write Go %s: %w", *goOut, err)
	}
	fmt.Fprintf(os.Stderr, "contract gen: wrote %s (%d bytes)\n", *goOut, len(goSrc))

	if *odinOut != "" {
		odinSrc, err := renderOdin(c)
		if err != nil {
			return fmt.Errorf("render Odin: %w", err)
		}
		if err := writeFile(*odinOut, odinSrc); err != nil {
			return fmt.Errorf("write Odin %s: %w", *odinOut, err)
		}
		fmt.Fprintf(os.Stderr, "contract gen: wrote %s (%d bytes)\n", *odinOut, len(odinSrc))
	}

	return nil
}

// repoRoot walks up from the current working directory to the first directory
// that contains a VERSION file — the repository root — so the generator runs
// correctly from any subdirectory of the module.
func repoRoot() (string, error) {
	cwd, err := os.Getwd()
	if err != nil {
		return "", fmt.Errorf("getwd: %w", err)
	}
	return repoRootFrom(cwd)
}

// repoRootFrom is repoRoot's testable core: it walks up from start to the dir
// holding a VERSION file.
func repoRootFrom(start string) (string, error) {
	dir := start
	for {
		if fi, err := os.Stat(filepath.Join(dir, "VERSION")); err == nil && !fi.IsDir() {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", fmt.Errorf("no VERSION file found walking up from %s", start)
		}
		dir = parent
	}
}

// writeFile writes content to path, creating parent directories as needed.
func writeFile(path string, content []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, content, 0o644)
}
