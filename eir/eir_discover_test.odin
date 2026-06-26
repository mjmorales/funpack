// Discovery-layer tests: the load layer's front half must (1) order its output by
// path so a lint never depends on filesystem-read order, (2) honor exclude globs
// by pruning directories and dropping files, and (3) tag each file test vs
// non-test by the _test.odin suffix. The fixture helpers here (a real temp tree,
// written then walked) are shared with eir_ast_test.odin, which parses what
// discovery finds.
package eir

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"

// test_discover_orders_deterministically pins that the same tree always yields the
// same sequence, in ascending path order — the property that makes a lint's output
// reproducible regardless of the directory-read order the walk happened to see.
@(test)
test_discover_orders_deterministically :: proc(t: ^testing.T) {
	root := fixture_root("order")
	defer remove_tree(root)

	write_fixture(root, "zebra.odin", "package p\n")
	write_fixture(root, "alpha.odin", "package p\n")
	write_fixture(root, "mango/fruit.odin", "package p\n")
	write_fixture(root, "apple.odin", "package p\n")

	first, ok1 := discover_odin_sources(root, nil, context.temp_allocator)
	testing.expect(t, ok1, "discovery must succeed over a readable root")
	second, ok2 := discover_odin_sources(root, nil, context.temp_allocator)
	testing.expect(t, ok2, "a repeat walk must also succeed")

	testing.expect_value(t, len(first), len(second))
	for i in 0 ..< len(first) {
		testing.expect_value(t, first[i].path, second[i].path)
	}
	for i in 1 ..< len(first) {
		testing.expect(
			t,
			first[i - 1].path < first[i].path,
			"discovered paths must be in ascending order",
		)
	}
}

// test_discover_honors_exclude_glob pins the exclude shapes: a directory pattern
// prunes the whole subtree (no descent), a file-name glob drops the matching file,
// and a trailing-slash directory pattern (`generated/`, the .gitignore form) prunes
// identically to the bare name — filepath.match cannot match a trailing separator,
// so glob_excludes strips it. Unmatched siblings survive throughout.
@(test)
test_discover_honors_exclude_glob :: proc(t: ^testing.T) {
	root := fixture_root("exclude")
	defer remove_tree(root)

	write_fixture(root, "keep.odin", "package p\n")
	write_fixture(root, "sub/also_keep.odin", "package p\n")
	write_fixture(root, "generated/skip.odin", "package p\n")
	write_fixture(root, "noise.gen.odin", "package p\n")

	sources, ok := discover_odin_sources(root, {"generated", "*.gen.odin"}, context.temp_allocator)
	testing.expect(t, ok, "discovery must succeed")
	testing.expect_value(t, len(sources), 2)

	for s in sources {
		testing.expect(
			t,
			!strings.contains(s.path, "generated"),
			"a pruned directory's files must not appear",
		)
		testing.expect(
			t,
			!strings.has_suffix(s.path, ".gen.odin"),
			"a file matching an exclude glob must not appear",
		)
	}
	testing.expect(t, has_basename(sources, "keep.odin"), "keep.odin must survive")
	testing.expect(t, has_basename(sources, "also_keep.odin"), "nested also_keep.odin must survive")

	slashed, slashed_ok := discover_odin_sources(root, {"generated/"}, context.temp_allocator)
	testing.expect(t, slashed_ok, "discovery must succeed with a trailing-slash exclude")
	for s in slashed {
		testing.expect(
			t,
			!strings.contains(s.path, "generated"),
			"a trailing-slash directory exclude must prune like the bare name",
		)
	}
	testing.expect(t, has_basename(slashed, "keep.odin"), "keep.odin must survive the slashed exclude")
}

// test_discover_tags_test_files pins the _test.odin classification: the tag the dup
// lint scopes by must be set from the filename suffix alone.
@(test)
test_discover_tags_test_files :: proc(t: ^testing.T) {
	root := fixture_root("tag")
	defer remove_tree(root)

	write_fixture(root, "widget.odin", "package p\n")
	write_fixture(root, "widget_test.odin", "package p\n")

	sources, ok := discover_odin_sources(root, nil, context.temp_allocator)
	testing.expect(t, ok, "discovery must succeed")
	testing.expect_value(t, len(sources), 2)

	for s in sources {
		switch filepath.base(s.path) {
		case "widget.odin":
			testing.expect(t, !s.is_test, "widget.odin is not a test file")
		case "widget_test.odin":
			testing.expect(t, s.is_test, "widget_test.odin is a test file")
		case:
			testing.expectf(t, false, "unexpected discovered file: %s", s.path)
		}
	}
}

// fixture_root returns a unique, freshly-cleaned directory under the system temp
// dir for one test to build a source tree in. The thread id keeps parallel test
// runs from colliding; the up-front remove_tree clears any leftover from an
// aborted prior run so a stale file never pollutes the walk.
fixture_root :: proc(label: string) -> string {
	base, terr := os.temp_dir(context.temp_allocator)
	if terr != nil {
		base = "."
	}
	root, _ := filepath.join(
		{base, fmt.tprintf("eir_load_test_%s_%d", label, os.get_current_thread_id())},
		context.temp_allocator,
	)
	remove_tree(root)
	_ = os.make_directory_all(root)
	return root
}

// write_fixture writes `content` to `root`/`rel`, creating any intervening
// directories so a test can declare a nested fixture in one line.
write_fixture :: proc(root, rel, content: string) {
	full, _ := filepath.join({root, rel}, context.temp_allocator)
	_ = os.make_directory_all(filepath.dir(full))
	_ = os.write_entire_file(full, content)
}

// remove_tree deletes a fixture tree best-effort. It walks the tree, then removes
// entries deepest-first (reverse-lexicographic order puts a child's path after its
// parent's, so children are unlinked before the now-empty parent). Errors are
// ignored: a leftover temp directory is harmless, and a test must not fail on
// cleanup.
remove_tree :: proc(root: string) {
	w := os.walker_create(root)
	defer os.walker_destroy(&w)

	paths := make([dynamic]string, 0, 16, context.temp_allocator)
	for info in os.walker_walk(&w) {
		if _, werr := os.walker_error(&w); werr != nil {
			continue
		}
		append(&paths, strings.clone(info.fullpath, context.temp_allocator))
	}

	slice.sort(paths[:])
	#reverse for p in paths {
		_ = os.remove(p)
	}
	_ = os.remove(root)
}

// load_source_fixture writes one source to a fresh temp tree, parses it through the
// loader, removes the temp files (the parsed tree lives in the temp allocator, independent
// of disk), and returns the Load_Result a lint-engine test consumes. Shared by the clone
// and near tiers' tests so neither carries its own copy of this setup.
load_source_fixture :: proc(label, src: string) -> Load_Result {
	root := fixture_root(label)
	write_fixture(root, "fix.odin", src)

	l: Loader
	loader_init(&l, context.temp_allocator)
	result, _ := load_dir(&l, root, nil)

	remove_tree(root)
	return result
}

// has_basename reports whether any discovered source has the given file name,
// independent of the temp-dir prefix the test cannot predict.
has_basename :: proc(sources: []Discovered, name: string) -> bool {
	for s in sources {
		if filepath.base(s.path) == name {
			return true
		}
	}
	return false
}
