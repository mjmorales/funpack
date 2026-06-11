// The §06/§07 grid-game golden: the snake example tree
// (funpack-spec/examples/snake) is the live source the declaration grammar must
// parse exactly and the full checked pipeline must compile and evaluate. The
// full-file fixture pins snake's declaration inventory against that source — when
// the spec evolves, the counts change in lockstep; never loosen them to ranges.
// Like the pong golden, the fixture resolves the sibling checkout (or
// FUNPACK_SNAKE_DIR) and SKIPs loudly when it is absent, so a missing checkout
// never silently passes. snake adds the things/behaviors model on a discrete
// grid: seeded-RNG food spawn/despawn, a game-over state machine, and
// signal-driven consumers (Eaten/Died), exercising the §08 list combinators
// (prepend/init/contains/concat/map/filter/is_empty), the §23 Input snapshot
// queries, and the §02 tuple-pattern match the pong surface never reaches.
package funpack

import "core:log"
import "core:os"
import "core:testing"

SNAKE_DEFAULT_DIR :: "../funpack-spec/examples/snake"

@(test)
test_golden_snake_full_file_parses :: proc(t: ^testing.T) {
	source, ok := snake_source()
	if !ok {
		return
	}
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	testing.expect(t, ast.module_doc != "")

	// The snake golden surface's exact declaration inventory (§06/§07): seven
	// imports; three enums (Dir, GameState, Move: Button — the role-enum form);
	// two data (Cell, Grid); one module-level let (GRID); two things (Snake,
	// Food); two signals (Eaten, Died); ten top-level fns (step_cell, cells,
	// body_after, off_grid, dir_from_input, cell_rect, occupied, all_cells,
	// bindings, setup); eleven behaviors (turn, advance, detect_eat, grow,
	// replenish, detect_death, apply_death, despawn_eaten, draw_snake, draw_state,
	// draw_food); one pipeline (Snake); four inline tests.
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

	// Spot-check the load-bearing details the count alone does not pin: the
	// role-enum kind on Move (the §23 button-action set), the singleton Snake's
	// defaulted fields, the pipeline's five ordered stages, and a behavior's
	// reserved step name and target.
	move, found_move := find_enum(ast, "Move")
	testing.expect(t, found_move)
	if found_move {
		testing.expect_value(t, move.kind, "Button")
		testing.expect_value(t, len(move.variants), 4)
	}

	snake, found_snake := find_thing(ast, "Snake")
	testing.expect(t, found_snake)
	if found_snake {
		// head/body/dir/grow/state — five fields, each defaulted (§03 §1).
		testing.expect_value(t, len(snake.fields), 5)
		testing.expect(t, snake.fields[0].has_default)
	}

	pipeline, found_pipeline := find_pipeline(ast, "Snake")
	testing.expect(t, found_pipeline)
	if found_pipeline {
		testing.expect_value(t, len(pipeline.stages), 5)
		testing.expect_value(t, pipeline.stages[0].name, "startup")
		testing.expect_value(t, pipeline.stages[4].name, "render")
		// eat: [detect_eat, grow, despawn_eaten, replenish] — the four-behavior stage.
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
	// The load-bearing acceptance: the full snake golden source typechecks
	// end-to-end through stage_typecheck — every behavior step body, helper fn,
	// bindings(), and setup() types over the resolved environment, with the §08
	// list combinators (concat/map/filter/contains over [Cell] and View[Food]),
	// the §23 Input queries, the tuple-returning replenish/setup, and the
	// tuple-pattern pick match all checking. The fixture resolves the live golden
	// source (or FUNPACK_SNAKE_DIR) and SKIPs loudly when absent.
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
	// The §06/§07 grid-game golden's defining outcome: the full snake source
	// compiles clean through every stage — parse → gates → typecheck → contracts →
	// flatten → effect-closure — and its four inline test blocks evaluate to their
	// golden values (four asserts, one per block): step_cell (a match over the Dir
	// enum returning a Cell), dir_from_input refuses a 180 (the §23 Input snapshot
	// seeded by Input.empty().with_pressed and queried by input.pressed, gated by
	// `and` and the enum `!=`), detect_death off the grid (the detect_death.step
	// behavior emitting a [Died] signal list, its off_grid guard reading the GRID
	// const through `or`/comparisons and contains over the body), and grow flags
	// growth (the grow.step behavior gated by is_empty over an inbound [Eaten]).
	// Passing all four exercises the §08 combinators, the §23 Input surface, and
	// the §04 name.step behavior invocation the pong golden does not reach. The
	// fixture reads the live golden source (or FUNPACK_SNAKE_DIR) and SKIPs loudly
	// when absent.
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

// snake_source reads the snake project's single source file via the §14
// project-tree reader; ok = false (with a SKIP warning) when the sibling
// checkout is absent, matching the pong golden's skip semantics.
snake_source :: proc() -> (source: string, ok: bool) {
	dir := resolve_snake_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP golden snake: %s not found — set FUNPACK_SNAKE_DIR or check out funpack-spec as a sibling of the repo", dir)
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
