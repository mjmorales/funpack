package funpack

import "core:log"
import "core:os"
import "core:testing"

SNAKE_DEFAULT_DIR :: "examples/snake"

@(test)
test_golden_snake_full_file_parses :: proc(t: ^testing.T) {
	source, ok := snake_source()
	if !ok {
		return
	}
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	testing.expect(t, ast.module_doc != "")

	testing.expect_value(t, len(ast.imports), 7)
	testing.expect_value(t, len(ast.enums), 3)
	testing.expect_value(t, len(ast.datas), 2)
	testing.expect_value(t, len(ast.lets), 1)
	testing.expect_value(t, len(ast.things), 2)
	testing.expect_value(t, len(ast.signals), 2)
	testing.expect_value(t, len(ast.fns), 10)
	testing.expect_value(t, len(ast.behaviors), 11)
	testing.expect_value(t, len(ast.pipelines), 1)
	testing.expect_value(t, len(ast.tests), 4)

	move, found_move := find_enum(ast, "Move")
	testing.expect(t, found_move)
	if found_move {
		testing.expect_value(t, move.kind, "Button")
		testing.expect_value(t, len(move.variants), 4)
	}

	snake, found_snake := find_thing(ast, "Snake")
	testing.expect(t, found_snake)
	if found_snake {
		testing.expect_value(t, len(snake.fields), 5)
		testing.expect(t, snake.fields[0].has_default)
	}

	pipeline, found_pipeline := find_pipeline(ast, "Snake")
	testing.expect(t, found_pipeline)
	if found_pipeline {
		testing.expect_value(t, len(pipeline.stages), 5)
		testing.expect_value(t, pipeline.stages[0].name, "startup")
		testing.expect_value(t, pipeline.stages[4].name, "render")
		testing.expect_value(t, len(pipeline.stages[2].behaviors), 4)
	}

	advance, found_advance := find_behavior(ast, "advance")
	testing.expect(t, found_advance)
	if found_advance {
		testing.expect_value(t, advance.target, "Snake")
		testing.expect_value(t, advance.step.name, "step")
	}
}

@(test)
test_golden_snake_full_file_typechecks :: proc(t: ^testing.T) {
	source, ok := snake_source()
	if !ok {
		return
	}
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	testing.expect_value(t, stage_gates(ast), Gate_Error.None)
	_, type_err := stage_typecheck(ast)
	testing.expect_value(t, type_err, Type_Error.None)
}

@(test)
test_golden_snake_full_pipeline_passes :: proc(t: ^testing.T) {
	source, ok := snake_source()
	if !ok {
		return
	}
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 4)
	testing.expect_value(t, report.failed, 0)
	testing.expect_value(t, report.exit_code, 0)
}

snake_source :: proc() -> (source: string, ok: bool) {
	dir := resolve_snake_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP golden snake: %s not found — set FUNPACK_SNAKE_DIR or ensure the in-repo fixture exists", dir)
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

resolve_snake_dir :: proc() -> string {
	return resolve_spec_dir("FUNPACK_SNAKE_DIR", SNAKE_DEFAULT_DIR)
}
