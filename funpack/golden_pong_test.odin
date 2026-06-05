// The §06/§07 gameplay golden: the pong example tree
// (funpack-spec/examples/pong) is the live source the declaration grammar
// must parse exactly. The full-file fixture pins the declaration counts
// against that source — when the spec evolves, the counts change in
// lockstep; never loosen them to ranges. Like the numerics golden, the
// fixture resolves the sibling checkout (or FUNPACK_PONG_DIR) and SKIPs
// loudly when it is absent, so a missing checkout never silently passes.
package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:testing"

PONG_DEFAULT_DIR :: "../funpack-spec/examples/pong"

@(test)
test_golden_pong_full_file_parses :: proc(t: ^testing.T) {
	source, ok := pong_source()
	if !ok {
		return
	}
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	testing.expect(t, ast.module_doc != "")

	// The pong golden surface's exact declaration inventory (§06/§07):
	// six imports; two enums (Side, Steer: Axis); one data (Board); one
	// module-level let (BOARD); three things (Paddle, Ball, Scoreboard);
	// one signal (Goal); nine top-level fns (advance, reflect_y, reflect_x,
	// overlaps, goal_side, serve_velocity, add_goal, bindings, setup); ten
	// behaviors (paddle_move, ball_move, wall_bounce, paddle_bounce, score,
	// tally, serve, draw_paddle, draw_ball, draw_score); one pipeline
	// (Pong); four inline tests.
	testing.expect_value(t, len(ast.imports), 6)
	testing.expect_value(t, len(ast.enums), 2)
	testing.expect_value(t, len(ast.datas), 1)
	testing.expect_value(t, len(ast.lets), 1)
	testing.expect_value(t, len(ast.things), 3)
	testing.expect_value(t, len(ast.signals), 1)
	testing.expect_value(t, len(ast.fns), 9)
	testing.expect_value(t, len(ast.behaviors), 10)
	testing.expect_value(t, len(ast.pipelines), 1)
	testing.expect_value(t, len(ast.tests), 4)

	// Spot-check the load-bearing details the count alone does not pin: the
	// enum-as-role kind, the singleton-vs-thing flag, the behavior step
	// reserved name and its target, and the pipeline's ordered stages.
	steer, found_steer := find_enum(ast, "Steer")
	testing.expect(t, found_steer)
	if found_steer {
		testing.expect_value(t, steer.kind, "Axis")
		testing.expect_value(t, len(steer.variants), 1)
	}

	scoreboard, found_score := find_thing(ast, "Scoreboard")
	testing.expect(t, found_score)
	if found_score {
		// Scoreboard's Int fields carry `= 0` defaults (§03 §1).
		testing.expect_value(t, len(scoreboard.fields), 2)
		testing.expect(t, scoreboard.fields[0].has_default)
	}

	pong, found_pong := find_pipeline(ast, "Pong")
	testing.expect(t, found_pong)
	if found_pong {
		testing.expect_value(t, len(pong.stages), 5)
		testing.expect_value(t, pong.stages[0].name, "startup")
		testing.expect_value(t, pong.stages[4].name, "render")
		testing.expect_value(t, len(pong.stages[3].behaviors), 3) // scoring: [score, tally, serve]
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
	// The load-bearing acceptance: the full pong golden source typechecks
	// end-to-end through stage_typecheck — every behavior step body, helper
	// fn, bindings(), and setup() types over the resolved environment, with
	// the View[Paddle]/first, fold(goals, self, add_goal),
	// input.value(self.player, Steer::Move), and `with`-update sites all
	// checking. The fixture resolves the live golden source (or
	// FUNPACK_PONG_DIR) and SKIPs loudly when absent.
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

// pong_source reads the pong project's single source file via the §14
// project-tree reader; ok = false (with a SKIP warning) when the sibling
// checkout is absent, matching the numerics golden's skip semantics.
pong_source :: proc() -> (source: string, ok: bool) {
	dir := resolve_pong_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP golden pong: %s not found — set FUNPACK_PONG_DIR or check out funpack-spec as a sibling of the repo", dir)
		return "", false
	}
	project, read_err := read_project(dir)
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
	dir, has_env := os.lookup_env("FUNPACK_PONG_DIR", context.temp_allocator)
	if !has_env || dir == "" {
		dir = PONG_DEFAULT_DIR
	}
	if filepath.is_abs(dir) {
		return dir
	}
	resolved, _ := filepath.join({#directory, "..", dir}, context.temp_allocator)
	return resolved
}

// find_enum / find_thing / find_pipeline / find_behavior are linear lookups
// by declared name over the parsed AST — the spot-check fixtures read one
// declaration without depending on its source position.
find_enum :: proc(ast: Ast, name: string) -> (Enum_Node, bool) {
	for decl in ast.enums {
		if decl.name == name {
			return decl, true
		}
	}
	return Enum_Node{}, false
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
