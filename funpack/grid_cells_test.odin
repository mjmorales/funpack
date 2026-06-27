package funpack

import "core:strings"
import "core:testing"

GRID_HEADER :: "import engine.grid.grid_cells\n" +
	"data Cell { x: Int, y: Int }\n"

typecheck_grid :: proc(body: string) -> Type_Error {
	source := strings.concatenate({GRID_HEADER, body}, context.temp_allocator)
	ast, parse_err := stage_parse(stage_lex(source))
	if parse_err != .None {
		return .Unsupported_Expr
	}
	_, err := stage_typecheck(ast)
	return err
}

@(test)
test_grid_cells_canonical_size_arg_types :: proc(t: ^testing.T) {
	err := typecheck_grid(
		"fn all_cells(size: Cell) -> [Cell] {\n" +
		"  return grid_cells(size)\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_grid_cells_canonical_non_record_arg_rejected :: proc(t: ^testing.T) {
	err := typecheck_grid(
		"fn bad(size: Cell) -> [Cell] {\n" +
		"  return grid_cells(1)\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_grid_cells_canonical_wrong_shape_rejected :: proc(t: ^testing.T) {
	wide := typecheck_grid(
		"data Wide { w: Int, h: Int }\n" +
		"fn bad(size: Wide) -> [Wide] {\n" +
		"  return grid_cells(size)\n" +
		"}\n")
	testing.expect_value(t, wide, Type_Error.Type_Mismatch)

	extra := typecheck_grid(
		"data Cell3 { x: Int, y: Int, z: Int }\n" +
		"fn bad(size: Cell3) -> [Cell3] {\n" +
		"  return grid_cells(size)\n" +
		"}\n")
	testing.expect_value(t, extra, Type_Error.Type_Mismatch)
}

@(test)
test_grid_cells_wrong_arity_rejected :: proc(t: ^testing.T) {
	err := typecheck_grid(
		"fn bad(size: Cell) -> [Cell] {\n" +
		"  return grid_cells(size, size)\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_grid_cells_mapper_form_still_types :: proc(t: ^testing.T) {
	err := typecheck_grid(
		"fn all_cells() -> [Cell] {\n" +
		"  return grid_cells(2, 3, fn(x, y) { return Cell{x: x, y: y} })\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_grid_cells_canonical_evaluates_row_major :: proc(t: ^testing.T) {
	report, err := run_test_pipeline(GRID_HEADER +
		"test \"canonical grid_cells walks row-major, y outer\" {\n" +
		"  assert grid_cells(Cell{x: 2, y: 2}) == [Cell{x: 0, y: 0}, Cell{x: 1, y: 0}, Cell{x: 0, y: 1}, Cell{x: 1, y: 1}]\n" +
		"  assert grid_cells(Cell{x: 2, y: 2}) == grid_cells(2, 2, fn(x, y) { return Cell{x: x, y: y} })\n" +
		"  assert grid_cells(Cell{x: 0, y: 3}) == []\n" +
		"}\n")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 3)
	testing.expect_value(t, report.failed, 0)
	testing.expect_value(t, report.exit_code, 0)
}

GRID_IMPORT_HEADER :: "import engine.grid.{Cell, grid_cells, neighbors, in_bounds}\n"

typecheck_grid_import :: proc(body: string) -> Type_Error {
	source := strings.concatenate({GRID_IMPORT_HEADER, body}, context.temp_allocator)
	ast, parse_err := stage_parse(stage_lex(source))
	if parse_err != .None {
		return .Unsupported_Expr
	}
	_, err := stage_typecheck(ast)
	return err
}

@(test)
test_imported_cell_types_structurally :: proc(t: ^testing.T) {
	err := typecheck_grid_import(
		"let MAP_SIZE: Cell = Cell{x: 16, y: 9}\n" +
		"fn step_right(c: Cell) -> Cell {\n" +
		"  return Cell{x: c.x + 1, y: c.y}\n" +
		"}\n" +
		"fn all_cells() -> [Cell] {\n" +
		"  return grid_cells(MAP_SIZE)\n" +
		"}\n" +
		"test \"imported Cell compares\" {\n" +
		"  assert step_right(Cell{x: 1, y: 2}) == Cell{x: 2, y: 2}\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_imported_cell_collides_with_local_decl :: proc(t: ^testing.T) {
	err := typecheck_grid_import("data Cell { x: Int, y: Int }\n")
	testing.expect_value(t, err, Type_Error.Name_Collision)
}

@(test)
test_neighbors_in_bounds_type_and_reject :: proc(t: ^testing.T) {
	clean := typecheck_grid_import(
		"import engine.list.{filter, len}\n" +
		"fn open_count(c: Cell, size: Cell) -> Int {\n" +
		"  return len(filter(neighbors(c), fn(n) { return in_bounds(n, size) }))\n" +
		"}\n")
	testing.expect_value(t, clean, Type_Error.None)

	non_cell := typecheck_grid_import(
		"import engine.list.len\n" +
		"fn bad() -> Int {\n" +
		"  return len(neighbors(3))\n" +
		"}\n")
	testing.expect_value(t, non_cell, Type_Error.Type_Mismatch)

	arity := typecheck_grid_import(
		"fn bad(c: Cell) -> Bool {\n" +
		"  return in_bounds(c)\n" +
		"}\n")
	testing.expect_value(t, arity, Type_Error.Type_Mismatch)
}

@(test)
test_grid_helpers_evaluate_exactly :: proc(t: ^testing.T) {
	report, err := run_test_pipeline(GRID_IMPORT_HEADER +
		"let SIZE: Cell = Cell{x: 3, y: 3}\n" +
		"test \"neighbors walks reading order\" {\n" +
		"  assert neighbors(Cell{x: 1, y: 1}) == [Cell{x: 1, y: 0}, Cell{x: 0, y: 1}, Cell{x: 2, y: 1}, Cell{x: 1, y: 2}]\n" +
		"}\n" +
		"test \"in_bounds gates the half-open grid\" {\n" +
		"  assert in_bounds(Cell{x: 0, y: 0}, SIZE) == true\n" +
		"  assert in_bounds(Cell{x: 2, y: 2}, SIZE) == true\n" +
		"  assert in_bounds(Cell{x: 3, y: 2}, SIZE) == false\n" +
		"  assert in_bounds(Cell{x: 2, y: 3}, SIZE) == false\n" +
		"  assert in_bounds(Cell{x: -1, y: 0}, SIZE) == false\n" +
		"  assert in_bounds(Cell{x: 0, y: -1}, SIZE) == false\n" +
		"}\n")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 7)
	testing.expect_value(t, report.failed, 0)
	testing.expect_value(t, report.exit_code, 0)
}

@(test)
test_imported_cell_rides_tilemap_queries :: proc(t: ^testing.T) {
	report, err := run_test_pipeline(
		"import engine.prelude.Option\n" +
		"import engine.math.Vec2\n" +
		"import engine.tilemap.{TilemapHandle}\n" +
		"import engine.grid.Cell\n" +
		"test \"imported Cell answers the layer queries\" {\n" +
		"  let map = TilemapHandle.of(16, [(Cell{x: 0, y: 0}, \"wall\", true), (Cell{x: 1, y: 0}, \"floor\", false)])\n" +
		"  assert map.tile_at(Cell{x: 1, y: 0}) == Option::Some(\"floor\")\n" +
		"  assert map.solid_at(Cell{x: 0, y: 0}) == true\n" +
		"  assert map.cell_of(Vec2{x: 24.0, y: 8.0}) == Cell{x: 1, y: 0}\n" +
		"  assert map.center_of(Cell{x: 1, y: 0}) == Vec2{x: 24.0, y: 8.0}\n" +
		"}\n")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 4)
	testing.expect_value(t, report.failed, 0)
}
