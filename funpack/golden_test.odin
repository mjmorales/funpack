package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:testing"

// The golden numerics tree lives in the funpack-spec sibling checkout.
// A relative FUNPACK_NUMERICS_DIR — and the documented default — resolves
// against the repo root, not the cwd, so `task funpack:test` (cwd
// funpack/) and a bare `odin test .` from anywhere behave identically.
GOLDEN_DEFAULT_DIR :: "../funpack-spec/examples/numerics"

@(test)
test_golden_numerics_full_file_parses :: proc(t: ^testing.T) {
	dir := resolve_golden_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP golden numerics: %s not found — set FUNPACK_NUMERICS_DIR or check out funpack-spec as a sibling of the repo", dir)
		return
	}
	project, read_err := read_project(dir)
	testing.expect_value(t, read_err, Project_Error.None)
	testing.expect_value(t, project.name, "numerics")
	testing.expect(t, len(project.sources) > 0)

	source_bytes, file_err := os.read_entire_file_from_path(project.sources[0], context.temp_allocator)
	testing.expect(t, file_err == nil)

	ast, parse_err := stage_parse(stage_lex(string(source_bytes)))
	testing.expect_value(t, parse_err, Parse_Error.None)
	testing.expect(t, ast.module_doc != "")
	testing.expect_value(t, len(ast.imports), 3)
	testing.expect_value(t, len(ast.tests), 12)

	assert_count := 0
	let_count := 0
	for test in ast.tests {
		// Every golden test block carries its own @doc.
		testing.expect(t, test.doc != "")
		for stmt in test.body {
			if _, is_assert := stmt.(Assert_Node); is_assert {
				assert_count += 1
			} else if _, is_let := stmt.(Let_Node); is_let {
				let_count += 1
			}
		}
	}
	testing.expect_value(t, assert_count, 30)
	testing.expect_value(t, let_count, 3)
}

resolve_golden_dir :: proc() -> string {
	dir, has_env := os.lookup_env("FUNPACK_NUMERICS_DIR", context.temp_allocator)
	if !has_env || dir == "" {
		dir = GOLDEN_DEFAULT_DIR
	}
	if filepath.is_abs(dir) {
		return dir
	}
	// #directory is this package dir; the repo root is one level up.
	resolved, _ := filepath.join({#directory, "..", dir}, context.temp_allocator)
	return resolved
}

@(test)
test_resolve_golden_dir_is_absolute :: proc(t: ^testing.T) {
	testing.expect(t, filepath.is_abs(resolve_golden_dir()))
}
