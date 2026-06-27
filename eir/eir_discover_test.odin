package eir

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"

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

write_fixture :: proc(root, rel, content: string) {
	full, _ := filepath.join({root, rel}, context.temp_allocator)
	_ = os.make_directory_all(filepath.dir(full))
	_ = os.write_entire_file(full, content)
}

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

load_source_fixture :: proc(label, src: string) -> Load_Result {
	root := fixture_root(label)
	write_fixture(root, "fix.odin", src)

	l: Loader
	loader_init(&l, context.temp_allocator)
	result, _ := load_dir(&l, root, nil)

	remove_tree(root)
	return result
}

has_basename :: proc(sources: []Discovered, name: string) -> bool {
	for s in sources {
		if filepath.base(s.path) == name {
			return true
		}
	}
	return false
}
