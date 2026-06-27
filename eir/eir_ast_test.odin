package eir

import "core:path/filepath"
import "core:strings"
import "core:testing"

GOOD_SOURCE :: `package good

Greeting :: "hi"

add :: proc(a, b: int) -> int {
	return a + b
}
`

BAD_SOURCE :: `package bad

Broken :: struct {
`

@(test)
test_load_file_parses_good_source :: proc(t: ^testing.T) {
	root := fixture_root("good")
	defer remove_tree(root)
	write_fixture(root, "good.odin", GOOD_SOURCE)
	path, _ := filepath.join({root, "good.odin"}, context.temp_allocator)

	l: Loader
	loader_init(&l, context.temp_allocator)
	defer loader_destroy(&l)

	file, ok := load_file(&l, path)
	testing.expect(t, ok, "a syntactically valid source parses clean")
	testing.expect(t, file != nil, "a good parse yields a non-nil ast.File")
	if file != nil {
		testing.expect_value(t, file.syntax_error_count, 0)
		testing.expect(t, len(file.decls) > 0, "the parsed file carries its declarations")
	}
}

@(test)
test_load_file_surfaces_parse_failure :: proc(t: ^testing.T) {
	root := fixture_root("bad")
	defer remove_tree(root)
	write_fixture(root, "bad.odin", BAD_SOURCE)
	path, _ := filepath.join({root, "bad.odin"}, context.temp_allocator)

	l: Loader
	loader_init(&l, context.temp_allocator)
	defer loader_destroy(&l)

	file, ok := load_file(&l, path)
	testing.expect(t, !ok, "a syntactically broken source is a parse failure")
	testing.expect(t, file != nil, "a parse failure still returns the partial tree")
	if file != nil {
		testing.expect(t, file.syntax_error_count > 0, "the syntax error is counted, not swallowed")
	}
}

@(test)
test_load_file_caches_by_path :: proc(t: ^testing.T) {
	root := fixture_root("cache")
	defer remove_tree(root)
	write_fixture(root, "thing.odin", GOOD_SOURCE)
	path, _ := filepath.join({root, "thing.odin"}, context.temp_allocator)

	l: Loader
	loader_init(&l, context.temp_allocator)
	defer loader_destroy(&l)

	first, ok1 := load_file(&l, path)
	second, ok2 := load_file(&l, path)
	testing.expect(t, ok1 && ok2, "both loads succeed")
	testing.expect(t, first == second, "a repeat load returns the cached tree, not a re-parse")
	testing.expect_value(t, len(l.cache), 1)
}

@(test)
test_load_dir_reports_failures_in_order :: proc(t: ^testing.T) {
	root := fixture_root("loaddir")
	defer remove_tree(root)
	write_fixture(root, "good_a.odin", GOOD_SOURCE)
	write_fixture(root, "good_b.odin", GOOD_SOURCE)
	write_fixture(root, "broken.odin", BAD_SOURCE)

	l: Loader
	loader_init(&l, context.temp_allocator)
	defer loader_destroy(&l)

	result, ok := load_dir(&l, root, nil)
	testing.expect(t, ok, "load_dir succeeds over a readable root")
	testing.expect_value(t, len(result.files), 2)
	testing.expect_value(t, result.parse_failures, 1)
	testing.expect_value(t, len(result.failures), 1)

	for loaded in result.files {
		testing.expect(t, loaded.file != nil, "every reported file has a parsed tree")
		testing.expect(
			t,
			!strings.has_suffix(loaded.path, "broken.odin"),
			"the broken file is a failure, not a parsed file",
		)
	}
	if len(result.files) == 2 {
		testing.expect(
			t,
			result.files[0].path < result.files[1].path,
			"parsed files follow ascending discovery order",
		)
	}
	if len(result.failures) == 1 {
		testing.expect(
			t,
			strings.has_suffix(result.failures[0], "broken.odin"),
			"the failure list names the broken file",
		)
	}
}
