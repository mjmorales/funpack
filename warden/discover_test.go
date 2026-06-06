package main

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// writeExecutable writes an executable stub file at dir/name and returns its
// path — the reusable scaffold for materializing fake funpack binaries that
// discovery's executable check accepts.
func writeExecutable(t *testing.T, dir, name string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatalf("write stub %s: %v", path, err)
	}
	return path
}

// envOf builds a LookupEnv closure over a fixed map so a test drives the
// override path without mutating the live process environment.
func envOf(pairs map[string]string) func(string) (string, bool) {
	return func(key string) (string, bool) {
		v, ok := pairs[key]
		return v, ok
	}
}

func TestDiscoverFunpack(t *testing.T) {
	// An override target and a repo-build target live in separate temp dirs so a
	// test can present either, both, or neither and pin which one precedence
	// selects.
	overrideDir := t.TempDir()
	overridePath := writeExecutable(t, overrideDir, "funpack-override")

	repoRoot := t.TempDir()
	if err := os.MkdirAll(filepath.Join(repoRoot, "funpack"), 0o755); err != nil {
		t.Fatalf("mkdir repo funpack/: %v", err)
	}
	repoBinary := writeExecutable(t, filepath.Join(repoRoot, "funpack"), "funpack")

	tests := []struct {
		name     string
		disc     Discovery
		wantPath string // absolute path expected; empty means expect ErrFunpackNotFound
		wantErr  error
	}{
		{
			name: "override wins over repo build",
			disc: Discovery{
				RepoRoot:  repoRoot,
				LookupEnv: envOf(map[string]string{FunpackBinEnv: overridePath}),
			},
			wantPath: mustAbs(t, overridePath),
		},
		{
			name: "repo build used when no override",
			disc: Discovery{
				RepoRoot:  repoRoot,
				LookupEnv: envOf(map[string]string{}),
			},
			wantPath: mustAbs(t, repoBinary),
		},
		{
			name: "set-but-unusable override is a hard error, not a fall-through",
			disc: Discovery{
				RepoRoot:  repoRoot, // a usable repo binary exists, but the override must NOT silently win
				LookupEnv: envOf(map[string]string{FunpackBinEnv: filepath.Join(overrideDir, "does-not-exist")}),
			},
			wantErr: os.ErrNotExist,
		},
		{
			name: "empty override string is ignored, falls to repo build",
			disc: Discovery{
				RepoRoot:  repoRoot,
				LookupEnv: envOf(map[string]string{FunpackBinEnv: ""}),
			},
			wantPath: mustAbs(t, repoBinary),
		},
		{
			name: "no override, no repo root, nothing on PATH errors typed",
			disc: Discovery{
				// RepoRoot empty -> repo-build step skipped; PATH scrubbed below.
				LookupEnv: envOf(map[string]string{}),
			},
			wantErr: ErrFunpackNotFound,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if tc.wantErr == ErrFunpackNotFound {
				// Guarantee the PATH branch cannot resolve a real funpack on the
				// host running the suite.
				t.Setenv("PATH", "")
			}

			got, err := tc.disc.DiscoverFunpack()

			if tc.wantErr != nil {
				if err == nil {
					t.Fatalf("expected error %v, got path %q", tc.wantErr, got)
				}
				if !errors.Is(err, tc.wantErr) {
					t.Fatalf("expected error wrapping %v, got %v", tc.wantErr, err)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tc.wantPath {
				t.Fatalf("path = %q, want %q", got, tc.wantPath)
			}
		})
	}
}

// TestDiscoverFunpackPathFallback covers the PATH branch in isolation: with no
// override and no repo root, a funpack on PATH is the last resort before the
// typed not-found error.
func TestDiscoverFunpackPathFallback(t *testing.T) {
	pathDir := t.TempDir()
	writeExecutable(t, pathDir, "funpack")
	t.Setenv("PATH", pathDir)

	disc := Discovery{LookupEnv: envOf(map[string]string{})}
	got, err := disc.DiscoverFunpack()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if want := mustAbs(t, filepath.Join(pathDir, "funpack")); got != want {
		t.Fatalf("path = %q, want %q", got, want)
	}
}

func mustAbs(t *testing.T, p string) string {
	t.Helper()
	abs, err := filepath.Abs(p)
	if err != nil {
		t.Fatalf("abs %s: %v", p, err)
	}
	return abs
}
