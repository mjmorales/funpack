package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

GOLDEN_DEFAULT_DIR :: "examples/numerics"

@(test)
test_golden_numerics_full_file_parses :: proc(t: ^testing.T) {
	dir := resolve_golden_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP golden numerics: %s not found — set FUNPACK_NUMERICS_DIR or ensure the in-repo fixture exists", dir)
		return
	}
	project, read_err, _ := read_project(dir)
	testing.expect_value(t, read_err, Project_Error.None)
	testing.expect_value(t, project.name, "numerics")
	testing.expect(t, len(project.sources) > 0)
	testing.expect_value(t, project.sources[0].module, "numerics")

	source_bytes, file_err := os.read_entire_file_from_path(project.sources[0].path, context.temp_allocator)
	testing.expect(t, file_err == nil)

	ast, parse_err := stage_parse(stage_lex(string(source_bytes)))
	testing.expect_value(t, parse_err, Parse_Error.None)
	testing.expect(t, ast.module_doc != "")
	testing.expect_value(t, len(ast.imports), 3)
	testing.expect_value(t, len(ast.tests), 12)

	assert_count := 0
	let_count := 0
	for test in ast.tests {
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

@(test)
test_golden_numerics_full_pipeline_passes :: proc(t: ^testing.T) {
	dir := resolve_golden_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP golden numerics: %s not found — set FUNPACK_NUMERICS_DIR or ensure the in-repo fixture exists", dir)
		return
	}
	project, read_err, _ := read_project(dir)
	testing.expect_value(t, read_err, Project_Error.None)
	testing.expect(t, len(project.sources) > 0)

	source_bytes, file_err := os.read_entire_file_from_path(project.sources[0].path, context.temp_allocator)
	testing.expect(t, file_err == nil)

	report, err := run_test_pipeline(string(source_bytes))
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 30)
	testing.expect_value(t, report.failed, 0)
	testing.expect_value(t, report.exit_code, 0)
}

golden_source :: proc() -> (source: string, ok: bool) {
	dir := resolve_golden_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP golden numerics: %s not found — set FUNPACK_NUMERICS_DIR or ensure the in-repo fixture exists", dir)
		return "", false
	}
	project, read_err, _ := read_project(dir)
	if read_err != .None || len(project.sources) == 0 {
		return "", false
	}
	source_bytes, file_err := os.read_entire_file_from_path(project.sources[0].path, context.temp_allocator)
	if file_err != nil {
		return "", false
	}
	return string(source_bytes), true
}

golden_variant :: proc(source: string, anchor: string, replacement: string) -> (variant: string, found: bool) {
	if !strings.contains(source, anchor) {
		return "", false
	}
	variant, _ = strings.replace(source, anchor, replacement, 1, context.temp_allocator)
	return variant, true
}

@(test)
test_golden_variant_removed_to_fixed_rejected :: proc(t: ^testing.T) {
	source, ok := golden_source()
	if !ok {
		return
	}
	variant, found := golden_variant(source, "to_fixed(2) + 0.5", "2 + 0.5")
	testing.expect(t, found)
	_, err := run_test_pipeline(variant)
	testing.expect_value(t, err, Pipeline_Error.Typecheck_Failed)
}

@(test)
test_golden_variant_unimported_name_rejected :: proc(t: ^testing.T) {
	source, ok := golden_source()
	if !ok {
		return
	}
	variant, found := golden_variant(source, "z: 1.0}, pi)", "z: 1.0}, tau)")
	testing.expect(t, found)
	_, err := run_test_pipeline(variant)
	testing.expect_value(t, err, Pipeline_Error.Typecheck_Failed)
}

resolve_golden_dir :: proc() -> string {
	return resolve_spec_dir("FUNPACK_NUMERICS_DIR", GOLDEN_DEFAULT_DIR)
}

resolve_spec_dir :: proc(env_name: string, default_rel: string) -> string {
	dir, has_env := os.lookup_env(env_name, context.temp_allocator)
	if !has_env || dir == "" {
		dir = default_rel
	}
	if filepath.is_abs(dir) {
		return dir
	}
	root, _ := filepath.join({#directory, ".."}, context.temp_allocator)
	resolved, _ := filepath.join({root, dir}, context.temp_allocator)
	return resolved
}

@(test)
test_resolve_golden_dir_is_absolute :: proc(t: ^testing.T) {
	testing.expect(t, filepath.is_abs(resolve_golden_dir()))
}
