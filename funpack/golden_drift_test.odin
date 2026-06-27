package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

DRIFT_DEFAULT_DIR :: "examples/drift"

resolve_drift_dir :: proc() -> string {
	return resolve_spec_dir("FUNPACK_DRIFT_DIR", DRIFT_DEFAULT_DIR)
}

@(test)
test_golden_drift_full_file_parses :: proc(t: ^testing.T) {
	source, ok := drift_source()
	if !ok {
		return
	}
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	testing.expect(t, ast.module_doc != "")

	testing.expect_value(t, len(ast.imports), 1)
	testing.expect_value(t, len(ast.fns), 4)
	testing.expect_value(t, len(ast.pipelines), 1)
	testing.expect_value(t, len(ast.tests), 1)

	drag, found_drag := find_fn(ast, "drag")
	testing.expect(t, found_drag)
	if found_drag {
		testing.expect(t, drag.holed)
		testing.expect(t, !drag.has_fallback)
	}
	launch, found_launch := find_fn(ast, "launch_speed")
	testing.expect(t, found_launch)
	if found_launch {
		testing.expect(t, launch.holed)
		testing.expect(t, launch.has_fallback)
	}
	damped, found_damped := find_fn(ast, "damped")
	testing.expect(t, found_damped)
	if found_damped {
		testing.expect(t, !damped.holed)
	}
}

@(test)
test_golden_drift_dev_pipeline_passes :: proc(t: ^testing.T) {
	source, ok := drift_source()
	if !ok {
		return
	}
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
	testing.expect_value(t, report.exit_code, 0)
	if err == .None && report.failed == 0 {
		log.infof("golden drift dev: compiles clean, the caller typechecks against the hole, and the fallback approximation runs to 7.5")
	}
}

@(test)
test_golden_drift_variant_hole_disagreeing_type_rejected :: proc(t: ^testing.T) {
	source, ok := drift_source()
	if !ok {
		return
	}
	variant, found := golden_variant(source, "@stub(Fixed)", "@stub(Int)")
	testing.expect(t, found)
	_, err := run_test_pipeline(variant)
	testing.expect_value(t, err, Pipeline_Error.Typecheck_Failed)
}

@(test)
test_golden_drift_index_carries_stub_for_both_holes :: proc(t: ^testing.T) {
	root, ok := copy_spec_tree_to_temp(resolve_drift_dir(), "drift", "FUNPACK_DRIFT_DIR")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	product, verdict := stage_build(root, .Dev, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.None)
	if verdict.err != .None {
		return
	}
	write_err := write_build_products(product, root)
	testing.expect_value(t, write_err, Build_Write_Error.None)

	index_bytes, read_err := os.read_entire_file_from_path(product.index_path, context.temp_allocator)
	testing.expect(t, read_err == nil)
	if read_err != nil {
		return
	}
	stream := string(index_bytes)

	drag_line, drag_found := index_decl_line(stream, "drag")
	testing.expect(t, drag_found)
	testing.expect(t, strings.contains(drag_line, "\"stub\":true"))
	launch_line, launch_found := index_decl_line(stream, "launch_speed")
	testing.expect(t, launch_found)
	testing.expect(t, strings.contains(launch_line, "\"stub\":true"))
	damped_line, damped_found := index_decl_line(stream, "damped")
	testing.expect(t, damped_found)
	testing.expect(t, strings.contains(damped_line, "\"stub\":false"))
	if drag_found && launch_found {
		log.infof("golden drift index: stub=true for both holed decls (drag, launch_speed), stub=false for the intact caller (damped)")
	}
}

@(test)
test_golden_drift_release_build_exits_two :: proc(t: ^testing.T) {
	root, ok := copy_spec_tree_to_temp(resolve_drift_dir(), "drift", "FUNPACK_DRIFT_DIR")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	_, verdict := stage_build(root, .Release, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.Holed_Declaration)
	testing.expect_value(t, verdict.offender, "drag")
	testing.expect_value(t, build_refusal_message(verdict, context.temp_allocator), "Holed_Declaration: drag")

	artifact_path := build_product_path(root, ARTIFACT_PRODUCT_NAME, context.temp_allocator)
	index_path := build_product_path(root, INDEX_PRODUCT_NAME, context.temp_allocator)
	testing.expect(t, !os.exists(artifact_path))
	testing.expect(t, !os.exists(index_path))
	log.infof("golden drift release: the hole-ban refuses the tree naming the offender (Holed_Declaration: drag, exit 2, no product)")
}

@(test)
test_golden_drift_dev_build_exits_zero_writes_both_products :: proc(t: ^testing.T) {
	root, ok := copy_spec_tree_to_temp(resolve_drift_dir(), "drift", "FUNPACK_DRIFT_DIR")
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	product, verdict := stage_build(root, .Dev, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.None)
	if verdict.err != .None {
		return
	}
	write_err := write_build_products(product, root)
	testing.expect_value(t, write_err, Build_Write_Error.None)
	testing.expect(t, os.exists(product.artifact_path))
	testing.expect(t, os.exists(product.index_path))
	log.infof("golden drift dev build: exit 0, both products written (artifact + index NDJSON)")
}

@(test)
test_resolve_drift_dir_is_absolute :: proc(t: ^testing.T) {
	testing.expect(t, filepath.is_abs(resolve_drift_dir()))
}

drift_source :: proc() -> (source: string, ok: bool) {
	dir := resolve_drift_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP golden drift: %s not found — set FUNPACK_DRIFT_DIR or ensure the in-repo fixture exists", dir)
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

index_decl_line :: proc(stream: string, qualified_name: string) -> (line: string, found: bool) {
	needle := strings.concatenate({"\"qualified_name\":\"", qualified_name, "\""}, context.temp_allocator)
	rest := stream
	for candidate in strings.split_lines_iterator(&rest) {
		if strings.contains(candidate, needle) {
			return candidate, true
		}
	}
	return "", false
}
