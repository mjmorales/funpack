package funpack

import "core:log"
import "core:os"
import "core:testing"

PONG_DEFAULT_DIR :: "examples/pong"

@(test)
test_golden_pong_full_file_parses :: proc(t: ^testing.T) {
	source, ok := pong_source()
	if !ok {
		return
	}
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	testing.expect(t, ast.module_doc != "")

	testing.expect_value(t, len(ast.imports), 6)
	testing.expect_value(t, len(ast.enums), 2)
	testing.expect_value(t, len(ast.datas), 1)
	testing.expect_value(t, len(ast.lets), 1)
	testing.expect_value(t, len(ast.things), 3)
	testing.expect_value(t, len(ast.signals), 1)
	testing.expect_value(t, len(ast.fns), 9)
	testing.expect_value(t, len(ast.behaviors), 10)
	testing.expect_value(t, len(ast.pipelines), 1)
	testing.expect_value(t, len(ast.tests), 5)

	steer, found_steer := find_enum(ast, "Steer")
	testing.expect(t, found_steer)
	if found_steer {
		testing.expect_value(t, steer.kind, "Axis")
		testing.expect_value(t, len(steer.variants), 1)
	}

	scoreboard, found_score := find_thing(ast, "Scoreboard")
	testing.expect(t, found_score)
	if found_score {
		testing.expect_value(t, len(scoreboard.fields), 2)
		testing.expect(t, scoreboard.fields[0].has_default)
	}

	pong, found_pong := find_pipeline(ast, "Pong")
	testing.expect(t, found_pong)
	if found_pong {
		testing.expect_value(t, len(pong.stages), 5)
		testing.expect_value(t, pong.stages[0].name, "startup")
		testing.expect_value(t, pong.stages[4].name, "render")
		testing.expect_value(t, len(pong.stages[3].behaviors), 3)
	}

	paddle_move, found_pm := find_behavior(ast, "paddle_move")
	testing.expect(t, found_pm)
	if found_pm {
		testing.expect_value(t, paddle_move.target, "Paddle")
		testing.expect_value(t, paddle_move.step.name, "step")
		testing.expect_value(t, len(paddle_move.step.params), 3)
	}
}

@(test)
test_golden_pong_full_file_typechecks :: proc(t: ^testing.T) {
	source, ok := pong_source()
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
test_golden_pong_full_pipeline_passes :: proc(t: ^testing.T) {
	source, ok := pong_source()
	if !ok {
		return
	}
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 8)
	testing.expect_value(t, report.failed, 0)
	testing.expect_value(t, report.exit_code, 0)
}

pong_source :: proc() -> (source: string, ok: bool) {
	dir := resolve_pong_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP golden pong: %s not found — set FUNPACK_PONG_DIR or ensure the in-repo fixture exists", dir)
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

resolve_pong_dir :: proc() -> string {
	return resolve_spec_dir("FUNPACK_PONG_DIR", PONG_DEFAULT_DIR)
}

find_thing :: proc(ast: Ast, name: string) -> (Thing_Node, bool) {
	for decl in ast.things {
		if decl.name == name {
			return decl, true
		}
	}
	return Thing_Node{}, false
}

find_pipeline :: proc(ast: Ast, name: string) -> (Pipeline_Node, bool) {
	for decl in ast.pipelines {
		if decl.name == name {
			return decl, true
		}
	}
	return Pipeline_Node{}, false
}

find_behavior :: proc(ast: Ast, name: string) -> (Behavior_Node, bool) {
	for decl in ast.behaviors {
		if decl.name == name {
			return decl, true
		}
	}
	return Behavior_Node{}, false
}
