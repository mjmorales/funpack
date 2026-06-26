// Filesystem discovery for the source lints: walk a root for .odin files,
// honoring an exclude-glob list and tagging each file test vs non-test. The walk
// order is filesystem-dependent, so discover_odin_sources sorts the result — a
// lint's output must never depend on directory-read order. Discovery is the load
// layer's front half; eir_ast.odin parses what it finds.
package eir

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

ODIN_EXT :: ".odin"
ODIN_TEST_SUFFIX :: "_test.odin"

// Discovered is one .odin source the walk found: its absolute path and whether it
// is an Odin test file (the _test.odin suffix Odin's build system uses to gate
// test compilation). is_test rides with the path so the dup lint can scope clone
// reporting to production vs test code without re-deriving it.
Discovered :: struct {
	path:    string,
	is_test: bool,
}

// discover_odin_sources walks `root` recursively and returns every .odin file as a
// Discovered, in ascending path order. excludes are glob patterns (filepath.match
// syntax) tested against BOTH each entry's path relative to root AND its base
// name: matching the base name lets `corpus` prune any directory so named at any
// depth (filepath.match has no `**`), while a relative pattern like `cmd/eir/*`
// scopes to one location and `*.gen.odin` targets generated files. A matched
// directory is PRUNED — not descended — and a matched file is omitted. ok is false
// only when the root cannot be resolved.
discover_odin_sources :: proc(
	root: string,
	excludes: []string,
	allocator := context.allocator,
) -> (
	sources: []Discovered,
	ok: bool,
) {
	abs_root, abs_err := filepath.abs(root, allocator)
	if abs_err != nil {
		return nil, false
	}
	defer delete(abs_root, allocator)

	found := make([dynamic]Discovered, 0, 64, allocator)

	w := os.walker_create(abs_root)
	defer os.walker_destroy(&w)

	for info in os.walker_walk(&w) {
		// A directory that failed to open mid-walk (a permission error, a race
		// with a concurrent rename) should drop that one entry, not abort the
		// whole scan — a lint over a large tree reports what it could read.
		if _, werr := os.walker_error(&w); werr != nil {
			continue
		}

		rel := path_relative_to(abs_root, info.fullpath)
		if glob_excludes(excludes, rel, info.name) {
			if info.type == .Directory {
				os.walker_skip_dir(&w)
			}
			continue
		}

		if info.type == .Directory {
			continue
		}
		if !strings.has_suffix(info.name, ODIN_EXT) {
			continue
		}

		// info.fullpath is the walker's reused buffer; clone it to outlive the
		// next walk step.
		append(
			&found,
			Discovered {
				path = strings.clone(info.fullpath, allocator),
				is_test = strings.has_suffix(info.name, ODIN_TEST_SUFFIX),
			},
		)
	}

	slice.sort_by(found[:], proc(a, b: Discovered) -> bool {
		return a.path < b.path
	})

	return found[:], true
}

// path_relative_to strips `root` and the separator after it from `full`, yielding
// `full` as seen from root. Both come from the same walk, so `full` always begins
// with `root`; the prefix guard returns `full` unchanged for the degenerate case
// where it does not, rather than slicing out of range.
path_relative_to :: proc(root, full: string) -> string {
	if !strings.has_prefix(full, root) {
		return full
	}
	return strings.trim_prefix(full[len(root):], os.Path_Separator_String)
}

// glob_excludes reports whether any pattern matches the entry, testing each
// against the relative path and then the base name. A malformed pattern
// (filepath.match returns an error) is treated as a non-match: the exclude list is
// curated lint configuration, so a bad pattern widens the scanned set rather than
// aborting the walk.
glob_excludes :: proc(patterns: []string, rel, name: string) -> bool {
	for pattern in patterns {
		if matched, err := filepath.match(pattern, rel); err == nil && matched {
			return true
		}
		if matched, err := filepath.match(pattern, name); err == nil && matched {
			return true
		}
	}
	return false
}
