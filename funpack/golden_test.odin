package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// The golden numerics tree lives in the funpack-spec sibling checkout.
// A relative FUNPACK_NUMERICS_DIR — and the documented default — resolves
// against the repo root, not the cwd, so `task funpack:test` (cwd
// funpack/) and a bare `odin test .` from anywhere behave identically.
GOLDEN_DEFAULT_DIR :: "../funpack-spec/examples/numerics"

@(test)
test_golden_numerics_first_assertion_passes :: proc(t: ^testing.T) {
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
	assert_stmt, found := first_assert_statement(string(source_bytes))
	testing.expect(t, found)

	wrapped := strings.concatenate({"test \"golden first assertion\" {\n", assert_stmt, "\n}\n"}, context.temp_allocator)
	report, err := run_test_pipeline(wrapped)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
	testing.expect_value(t, report.exit_code, 0)
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

// first_assert_statement returns the first `assert …` statement in the
// golden source. The thin pipeline parses only the trivial-assert
// grammar, so the golden test drives exactly one statement through it;
// the widening grammar retires this extraction in favor of feeding the
// whole file.
first_assert_statement :: proc(source: string) -> (stmt: string, found: bool) {
	it := source
	for raw_line in strings.split_lines_iterator(&it) {
		trimmed := strings.trim_space(raw_line)
		if strings.has_prefix(trimmed, "assert ") {
			return trimmed, true
		}
	}
	return "", false
}

@(test)
test_first_assert_statement_finds_leading_assert :: proc(t: ^testing.T) {
	source := "@doc(\"…\")\nimport engine.math.to_fixed\n\ntest \"x\" {\n  assert to_fixed(2) == 2.0\n  assert to_fixed(2) + 0.5 == 2.5\n}\n"
	stmt, found := first_assert_statement(source)
	testing.expect(t, found)
	testing.expect_value(t, stmt, "assert to_fixed(2) == 2.0")
}

@(test)
test_first_assert_statement_none :: proc(t: ^testing.T) {
	_, found := first_assert_statement("test \"empty\" {\n}\n")
	testing.expect(t, !found)
}

@(test)
test_resolve_golden_dir_is_absolute :: proc(t: ^testing.T) {
	testing.expect(t, filepath.is_abs(resolve_golden_dir()))
}
