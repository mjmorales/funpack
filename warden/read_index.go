// Index Contract product read-back: after a build, the §14 derived NDJSON index
// product sits at a path warden derives from the SAME tree root it ran the build
// against. This seam reads that product back as a RAW byte stream and nothing
// more. Its scope boundary is absolute and deliberate: it returns bytes, never
// records — no encoding/json, no line splitting, no schema_version inspection,
// no field interpretation. Decoding the NDJSON into typed records is the
// schema-decoder epic's job (warden/index/), layered on top of these raw bytes;
// coupling the read to the parse here would collapse that separation.
package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// FunpackBuildDir is the §14 derived-products directory leaf (`.funpack/`) under
// the project root, mirroring funpack/build.odin's FUNPACK_BUILD_DIR. warden
// re-derives it here rather than reading it from funpack because the only
// coupling permitted across the §29 process boundary is the CLI invocation, not
// a shared symbol — the two definitions are intentional twins, kept in sync by
// the fixed §14 contract, not by a link.
const FunpackBuildDir = ".funpack"

// IndexProductName is the Index Contract product's fixed leaf name under
// `.funpack/`, mirroring funpack/build.odin's INDEX_PRODUCT_NAME. The `.ndjson`
// extension names the one-object-per-line stream this seam returns untouched.
const IndexProductName = "index.ndjson"

// ErrIndexNotFound is the typed sentinel returned when the Index Contract
// product is absent at its derived path — the expected outcome after a Failure
// build that wrote no product. Callers match it with errors.Is to distinguish
// "no index to read" from a genuine IO fault reading one that exists.
var ErrIndexNotFound = errors.New("warden: index product not found at derived path")

// IndexProductPath derives the Index Contract product's absolute-relative
// location from the tree root the build ran against: <root>/.funpack/index.ndjson.
// It is a pure function of the root and the fixed §14 leaf names — the same join
// funpack performs in build_product_path — so no machine path is ever baked in,
// and the path resolves deterministically for any root the caller supplies.
func IndexProductPath(treeRoot string) string {
	return filepath.Join(treeRoot, FunpackBuildDir, IndexProductName)
}

// ReadIndex reads back the raw Index Contract NDJSON byte stream from the product
// derived under treeRoot. The returned slice is byte-identical to the on-disk
// product: no decode, no line splitting, no transformation of any kind happens
// here. A missing product surfaces as ErrIndexNotFound (the post-Failure-build
// case); any other read fault is wrapped with the resolved path for diagnosis.
// Neither absence nor an IO fault is ever an empty-bytes success — both are
// errors the caller must branch on.
func ReadIndex(treeRoot string) ([]byte, error) {
	path := IndexProductPath(treeRoot)

	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, fmt.Errorf("%w: %s", ErrIndexNotFound, path)
		}
		return nil, fmt.Errorf("warden: reading index product %s: %w", path, err)
	}

	return data, nil
}
