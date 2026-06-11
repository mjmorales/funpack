// The §18 §4 TilemapHandle.of fixture + layer-query surface: the View.of/
// Nav.of-mold static builder an inline test seeds a tile layer with, and the
// four queries (tile_at/solid_at/cell_of/center_of) answering over it in the
// dungeon's method-style spelling (map.tile_at(cell)). Pins are exact and
// self-contained (no sibling checkout): the surface rows, the bare-import
// resolution, typecheck accept/reject fixtures, and end-to-end evaluation
// with exact fixed-point answers — out-of-grid tile_at is Option::None and
// solid_at false (total, never a fault), cell_of floor-divides (a negative
// position lands in the correct negative cell), center_of is origin + half
// cell in the fixture's own origin-anchored grid-local space.
package funpack

import "core:testing"

@(test)
test_tilemap_fixture_surface_rows :: proc(t: ^testing.T) {
	// AC: TilemapHandle.of resolves as a static builder yielding the handle,
	// and the four §18 §4 queries resolve as engine methods off the handle
	// receiver with their exact result shapes.
	of, has_of := surface_static_method("TilemapHandle", "of")
	testing.expect(t, has_of)
	testing.expect(t, returns_engine(of, .TilemapHandle))

	recv := engine_type_of(.TilemapHandle).(^Engine_Type)

	tile_at, has_tile_at := surface_engine_method(recv, "tile_at")
	testing.expect(t, has_tile_at)
	if has_tile_at {
		signature := tile_at.(^Func_Type)
		option, is_option := signature.result.(^Option_Type)
		testing.expect(t, is_option)
		if is_option {
			testing.expect(t, is_engine(option.elem, .String))
		}
	}

	solid_at, has_solid_at := surface_engine_method(recv, "solid_at")
	testing.expect(t, has_solid_at)
	if has_solid_at {
		testing.expect(t, is_ground(solid_at.(^Func_Type).result, .Bool))
	}

	cell_of, has_cell_of := surface_engine_method(recv, "cell_of")
	testing.expect(t, has_cell_of)
	if has_cell_of {
		signature := cell_of.(^Func_Type)
		// The result is the user's own Cell record — no checker ground (the
		// grid_cells discipline), so it is the nil unknown; the position
		// parameter is the exact Vec2 ground.
		testing.expect(t, signature.result == nil)
		testing.expect_value(t, len(signature.params), 1)
		testing.expect(t, is_ground(signature.params[0], .Vec2))
	}

	center_of, has_center_of := surface_engine_method(recv, "center_of")
	testing.expect(t, has_center_of)
	if has_center_of {
		testing.expect(t, is_ground(center_of.(^Func_Type).result, .Vec2))
	}
}

@(test)
test_tilemap_queries_resolve_as_imports :: proc(t: ^testing.T) {
	// AC: the dungeon's bare import line resolves — the four queries bind to
	// engine.tilemap as Func rows (their typing rule is the engine-method
	// call site, the AtlasHandle cell/frame mold).
	source := "import engine.tilemap.{tile_at, solid_at, cell_of, center_of}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	bindings, err := resolve_imports(ast)
	testing.expect_value(t, err, Type_Error.None)
	if err != .None {
		return
	}
	expect_bindings(t, bindings, {
		{"tile_at", "engine.tilemap", .Func},
		{"solid_at", "engine.tilemap", .Func},
		{"cell_of", "engine.tilemap", .Func},
		{"center_of", "engine.tilemap", .Func},
	})
}

// TILEMAP_FIXTURE_PREAMBLE is the shared import/schema head of the inline
// fixtures: the handle type, the Option/Vec2 grounds, and the user's own Cell
// record (engine.grid's Cell is the user's record by the grid_cells
// discipline, so the fixture declares it locally).
TILEMAP_FIXTURE_PREAMBLE :: "import engine.prelude.Option\n" +
	"import engine.math.Vec2\n" +
	"import engine.tilemap.{TilemapHandle}\n" +
	"data Cell { x: Int, y: Int }\n"

@(test)
test_tilemap_fixture_typechecks :: proc(t: ^testing.T) {
	// AC (typecheck accept): the fixture seeds a layer and all four queries
	// compose into assert positions — the §23 §5 / §12 §3 inline-test mold.
	source := TILEMAP_FIXTURE_PREAMBLE +
		"test \"queries type over a seeded layer\" {\n" +
		"  let map = TilemapHandle.of(16, [(Cell{x: 0, y: 0}, \"wall\", true)])\n" +
		"  assert map.tile_at(Cell{x: 0, y: 0}) == Option::Some(\"wall\")\n" +
		"  assert map.solid_at(Cell{x: 0, y: 0}) == true\n" +
		"  assert map.cell_of(Vec2{x: 8.0, y: 8.0}) == Cell{x: 0, y: 0}\n" +
		"  assert map.center_of(Cell{x: 0, y: 0}) == Vec2{x: 8.0, y: 8.0}\n" +
		"}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := stage_typecheck(ast)
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_tilemap_queries_type_on_seam_handle :: proc(t: ^testing.T) {
	// AC (typecheck accept): the queries ride the HANDLE TYPE, not the fixture
	// builder — a seam-shaped record-literal handle (`TilemapHandle{name: …}`)
	// admits the same method calls, so the dungeon's behaviors typecheck
	// against the level seam's layer constant.
	source := TILEMAP_FIXTURE_PREAMBLE +
		"fn probe(map: TilemapHandle, target: Cell) -> Bool {\n" +
		"  return map.solid_at(target)\n" +
		"}\n" +
		"test \"a seam handle types the queries\" {\n" +
		"  assert probe(TilemapHandle{name: \"terrain\"}, Cell{x: 1, y: 1}) == false\n" +
		"}\n"
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := stage_typecheck(ast)
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_tilemap_fixture_rejects_malformed_shapes :: proc(t: ^testing.T) {
	// AC (typecheck reject, one fixture per arm): a Fixed cell size, a
	// non-Bool solid tuple position, a query arity miss, and an unknown
	// method each surface their named verdict — never a silent admit.
	fixed_size, fs_parse := stage_parse(stage_lex(TILEMAP_FIXTURE_PREAMBLE +
		"test \"fixed cell size refused\" {\n" +
		"  let map = TilemapHandle.of(16.0, [(Cell{x: 0, y: 0}, \"wall\", true)])\n" +
		"  assert map.solid_at(Cell{x: 0, y: 0}) == true\n" +
		"}\n"))
	testing.expect_value(t, fs_parse, Parse_Error.None)
	_, fixed_err := stage_typecheck(fixed_size)
	testing.expect_value(t, fixed_err, Type_Error.Type_Mismatch)

	int_solid, is_parse := stage_parse(stage_lex(TILEMAP_FIXTURE_PREAMBLE +
		"test \"non-Bool solid refused\" {\n" +
		"  let map = TilemapHandle.of(16, [(Cell{x: 0, y: 0}, \"wall\", 1)])\n" +
		"  assert map.solid_at(Cell{x: 0, y: 0}) == true\n" +
		"}\n"))
	testing.expect_value(t, is_parse, Parse_Error.None)
	_, solid_err := stage_typecheck(int_solid)
	testing.expect_value(t, solid_err, Type_Error.Type_Mismatch)

	arity, ar_parse := stage_parse(stage_lex(TILEMAP_FIXTURE_PREAMBLE +
		"test \"query arity miss refused\" {\n" +
		"  let map = TilemapHandle.of(16, [(Cell{x: 0, y: 0}, \"wall\", true)])\n" +
		"  assert map.solid_at() == true\n" +
		"}\n"))
	testing.expect_value(t, ar_parse, Parse_Error.None)
	_, arity_err := stage_typecheck(arity)
	testing.expect_value(t, arity_err, Type_Error.Type_Mismatch)

	unknown, un_parse := stage_parse(stage_lex(TILEMAP_FIXTURE_PREAMBLE +
		"test \"unknown query refused\" {\n" +
		"  let map = TilemapHandle.of(16, [(Cell{x: 0, y: 0}, \"wall\", true)])\n" +
		"  assert map.warp(Cell{x: 0, y: 0}) == true\n" +
		"}\n"))
	testing.expect_value(t, un_parse, Parse_Error.None)
	_, unknown_err := stage_typecheck(unknown)
	testing.expect_value(t, unknown_err, Type_Error.Unsupported_Expr)
}

@(test)
test_tilemap_fixture_evaluates_queries :: proc(t: ^testing.T) {
	// AC (evaluation, exact pins): a seeded layer answers all four queries —
	// tile_at reads the seeded name (and None off-grid, total), solid_at the
	// seeded verdict (and false off-grid), cell_of floor-divides into the
	// containing cell including the exact-boundary and negative-position
	// arms, center_of reads origin + half cell, negative cells included.
	report, err := run_test_pipeline(TILEMAP_FIXTURE_PREAMBLE +
		"test \"tile_at reads seeded and unseeded cells\" {\n" +
		"  let map = TilemapHandle.of(16, [(Cell{x: 0, y: 0}, \"wall\", true), (Cell{x: 1, y: 0}, \"floor\", false), (Cell{x: 2, y: 1}, \"rubble\", true)])\n" +
		"  assert map.tile_at(Cell{x: 0, y: 0}) == Option::Some(\"wall\")\n" +
		"  assert map.tile_at(Cell{x: 2, y: 1}) == Option::Some(\"rubble\")\n" +
		"  assert map.tile_at(Cell{x: 3, y: 0}) == Option::None\n" +
		"  assert map.tile_at(Cell{x: 99, y: -5}) == Option::None\n" +
		"}\n" +
		"test \"solid_at reads the collision verdict\" {\n" +
		"  let map = TilemapHandle.of(16, [(Cell{x: 0, y: 0}, \"wall\", true), (Cell{x: 1, y: 0}, \"floor\", false)])\n" +
		"  assert map.solid_at(Cell{x: 0, y: 0}) == true\n" +
		"  assert map.solid_at(Cell{x: 1, y: 0}) == false\n" +
		"  assert map.solid_at(Cell{x: 7, y: 7}) == false\n" +
		"}\n" +
		"test \"cell_of floor-divides the position\" {\n" +
		"  let map = TilemapHandle.of(16, [(Cell{x: 0, y: 0}, \"floor\", false)])\n" +
		"  assert map.cell_of(Vec2{x: 8.0, y: 8.0}) == Cell{x: 0, y: 0}\n" +
		"  assert map.cell_of(Vec2{x: 16.0, y: 31.5}) == Cell{x: 1, y: 1}\n" +
		"  assert map.cell_of(Vec2{x: 15.5, y: 0.0}) == Cell{x: 0, y: 0}\n" +
		"  assert map.cell_of(Vec2{x: -0.5, y: -16.0}) == Cell{x: -1, y: -1}\n" +
		"}\n" +
		"test \"center_of reads origin plus half cell\" {\n" +
		"  let map = TilemapHandle.of(16, [(Cell{x: 0, y: 0}, \"floor\", false)])\n" +
		"  assert map.center_of(Cell{x: 0, y: 0}) == Vec2{x: 8.0, y: 8.0}\n" +
		"  assert map.center_of(Cell{x: 2, y: 1}) == Vec2{x: 40.0, y: 24.0}\n" +
		"  assert map.center_of(Cell{x: -1, y: 0}) == Vec2{x: -8.0, y: 8.0}\n" +
		"}\n" +
		"test \"an odd cell size centers on the exact dyadic half\" {\n" +
		"  let map = TilemapHandle.of(5, [(Cell{x: 0, y: 0}, \"floor\", false)])\n" +
		"  assert map.center_of(Cell{x: 0, y: 0}) == Vec2{x: 2.5, y: 2.5}\n" +
		"  assert map.cell_of(Vec2{x: 4.5, y: 5.0}) == Cell{x: 0, y: 1}\n" +
		"}\n")
	testing.expect_value(t, err, Pipeline_Error.None)
	// report.passed counts ASSERTS (the §18 §4 pins: 4+3+4+3+2), not blocks.
	testing.expect_value(t, report.passed, 16)
	testing.expect_value(t, report.failed, 0)
	testing.expect_value(t, report.exit_code, 0)
}

@(test)
test_tilemap_empty_fixture_is_total :: proc(t: ^testing.T) {
	// AC (totality): an EMPTY fixture answers every membership query with the
	// defined zero — None / not-solid — never a fault; the dungeon's
	// `enterable` decision composes over it exactly as over a seeded layer.
	report, err := run_test_pipeline(TILEMAP_FIXTURE_PREAMBLE +
		"test \"the empty layer reads None and not-solid\" {\n" +
		"  let map = TilemapHandle.of(16, [])\n" +
		"  assert map.tile_at(Cell{x: 0, y: 0}) == Option::None\n" +
		"  assert map.solid_at(Cell{x: 0, y: 0}) == false\n" +
		"  assert map.center_of(Cell{x: 1, y: 1}) == Vec2{x: 24.0, y: 24.0}\n" +
		"}\n")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 3) // three asserts, one block
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_tilemap_fixture_gates_handle_decision :: proc(t: ^testing.T) {
	// AC (the consumer's seat): the dungeon's handle-touching movement gate —
	// enter a passable cell, refuse a wall, refuse the void — is testable as
	// ONE decision over the fixture instead of decomposing into pure fns;
	// the exact shape the task's "every decision had to decompose" pain names.
	report, err := run_test_pipeline(TILEMAP_FIXTURE_PREAMBLE +
		"fn enter(map: TilemapHandle, target: Cell, stay: Vec2) -> Vec2 {\n" +
		"  let blocked = match map.tile_at(target) {\n" +
		"    Option::Some(_) => map.solid_at(target)\n" +
		"    Option::None => true\n" +
		"  }\n" +
		"  if blocked { return stay }\n" +
		"  return map.center_of(target)\n" +
		"}\n" +
		"test \"the movement gate walks the fixture layer\" {\n" +
		"  let map = TilemapHandle.of(16, [(Cell{x: 0, y: 0}, \"wall\", true), (Cell{x: 1, y: 0}, \"floor\", false)])\n" +
		"  let stay = Vec2{x: 100.0, y: 100.0}\n" +
		"  assert enter(map, Cell{x: 1, y: 0}, stay) == Vec2{x: 24.0, y: 8.0}\n" +
		"  assert enter(map, Cell{x: 0, y: 0}, stay) == stay\n" +
		"  assert enter(map, Cell{x: 5, y: 5}, stay) == stay\n" +
		"}\n")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 3) // three asserts, one block
	testing.expect_value(t, report.failed, 0)
}
