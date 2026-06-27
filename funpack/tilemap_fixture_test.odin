package funpack

import "core:testing"

@(test)
test_tilemap_fixture_surface_rows :: proc(t: ^testing.T) {
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

TILEMAP_FIXTURE_PREAMBLE :: "import engine.prelude.Option\n" +
	"import engine.math.Vec2\n" +
	"import engine.tilemap.{TilemapHandle}\n" +
	"data Cell { x: Int, y: Int }\n"

@(test)
test_tilemap_fixture_typechecks :: proc(t: ^testing.T) {
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
	testing.expect_value(t, unknown_err, Type_Error.Unknown_Method)
}

@(test)
test_tilemap_fixture_evaluates_queries :: proc(t: ^testing.T) {
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
	testing.expect_value(t, report.passed, 16)
	testing.expect_value(t, report.failed, 0)
	testing.expect_value(t, report.exit_code, 0)
}

@(test)
test_tilemap_empty_fixture_is_total :: proc(t: ^testing.T) {
	report, err := run_test_pipeline(TILEMAP_FIXTURE_PREAMBLE +
		"test \"the empty layer reads None and not-solid\" {\n" +
		"  let map = TilemapHandle.of(16, [])\n" +
		"  assert map.tile_at(Cell{x: 0, y: 0}) == Option::None\n" +
		"  assert map.solid_at(Cell{x: 0, y: 0}) == false\n" +
		"  assert map.center_of(Cell{x: 1, y: 1}) == Vec2{x: 24.0, y: 24.0}\n" +
		"}\n")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 3)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_tilemap_fixture_gates_handle_decision :: proc(t: ^testing.T) {
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
	testing.expect_value(t, report.passed, 3)
	testing.expect_value(t, report.failed, 0)
}
