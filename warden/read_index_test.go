package main

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// seedIndexProduct materializes a `.funpack/index.ndjson` under root carrying
// content exactly, returning root. It is the fixture scaffold the read-back
// tests build a known on-disk product from so the assertion can be a raw byte
// comparison against what was written.
func seedIndexProduct(t *testing.T, root string, content []byte) {
	t.Helper()
	buildDir := filepath.Join(root, FunpackBuildDir)
	if err := os.MkdirAll(buildDir, 0o755); err != nil {
		t.Fatalf("mkdir build dir %s: %v", buildDir, err)
	}
	if err := os.WriteFile(filepath.Join(buildDir, IndexProductName), content, 0o644); err != nil {
		t.Fatalf("write index product: %v", err)
	}
}

func TestReadIndex(t *testing.T) {
	root := t.TempDir()
	// A multi-line NDJSON byte string with a trailing newline: the read-back must
	// preserve it verbatim, proving no line splitting or trailing-newline
	// normalization touches the stream.
	want := []byte(`{"schema_version":1,"kind":"project"}` + "\n" +
		`{"kind":"entrypoint","name":"main"}` + "\n")
	seedIndexProduct(t, root, want)

	got, err := ReadIndex(root)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if string(got) != string(want) {
		t.Fatalf("read-back is not byte-identical:\n got %q\nwant %q", got, want)
	}
}

func TestReadIndexMissing(t *testing.T) {
	// A root with no `.funpack/index.ndjson` stands in for the post-Failure-build
	// case where no product was written. The read must surface the typed sentinel,
	// never a nil-error empty-bytes success.
	root := t.TempDir()

	got, err := ReadIndex(root)
	if err == nil {
		t.Fatalf("expected ErrIndexNotFound for a missing product, got %d bytes and nil error", len(got))
	}
	if !errors.Is(err, ErrIndexNotFound) {
		t.Fatalf("expected error wrapping ErrIndexNotFound, got %v", err)
	}
	if got != nil {
		t.Fatalf("a missing product must return nil bytes, got %q", got)
	}
}

func TestIndexProductPath(t *testing.T) {
	// Path resolution is a pure function of the root: two distinct roots must each
	// resolve to <root>/.funpack/index.ndjson, with no absolute machine path baked
	// into the source.
	roots := []string{
		filepath.Join("alpha", "tree"),
		filepath.Join("beta", "other", "tree"),
	}
	for _, root := range roots {
		want := filepath.Join(root, ".funpack", "index.ndjson")
		if got := IndexProductPath(root); got != want {
			t.Errorf("IndexProductPath(%q) = %q, want %q", root, got, want)
		}
	}
}
