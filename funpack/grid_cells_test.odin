// The §18 §4 grid_cells fixtures: the CANONICAL grid_cells(size: Cell) ->
// [Cell] form beside the kept non-idiomatic 3-arg mapper, both selected by
// arity off the one engine.grid Func row. Typing pins the cell-shape judgment
// (a record of exactly {x: Int, y: Int}, never a name match) and the
// named rejects for a wrong argument type, a wrong shape, and a wrong arity;
// evaluation pins the EXACT row-major cell list (y outer, x inner — verified
// against the mapper form's loop) and that both arities enumerate identically.
//
// Plus the COMPLETED §26 engine.grid row (the dungeon's import surface):
// `Cell` admitted as the stdlib's STRUCTURAL data record — an imported Cell
// types and evaluates exactly as the user-declared one (annotation,
// construction, projection, equality, cell-shape), with no engine ground
// minted (the grid_cells discipline holds) — and the neighbors/in_bounds
// helpers with their cell-shape typing, named rejects, and exact evaluation
// pins (row-major-reading neighbor order; the [0, size) bounds verdict).
package funpack

import "core:strings"
import "core:testing"

// GRID_HEADER declares the minimal §18 grid surface independent of the golden
// checkout: the engine.grid helper import and a user Cell record of the
// canonical {x: Int, y: Int} shape. A fixture appends one fn/test body and
// drives the whole source.
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
	// AC (canonical typing): grid_cells(size) over a user Cell record yields
	// [Cell] — the result element is the size argument's OWN type, written here
	// into a [Cell]-returning fn so the list type is checked, not assumed.
	err := typecheck_grid(
		"fn all_cells(size: Cell) -> [Cell] {\n" +
		"  return grid_cells(size)\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_grid_cells_canonical_non_record_arg_rejected :: proc(t: ^testing.T) {
	// AC (named reject, wrong argument type): a bare Int where the canonical
	// form wants a cell record is a Type_Mismatch — the 1-arg form never falls
	// back to a mapper-dimension reading.
	err := typecheck_grid(
		"fn bad(size: Cell) -> [Cell] {\n" +
		"  return grid_cells(1)\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_grid_cells_canonical_wrong_shape_rejected :: proc(t: ^testing.T) {
	// AC (named reject, wrong record shape): the cell-shape judgment is the
	// schema — exactly the two Int fields x and y. A record with different
	// field names rejects, and so does a record carrying a THIRD field (the
	// evaluator constructs cells of only x and y, so a wider record could never
	// be rebuilt faithfully).
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
	// AC (named reject, wrong count): arity selects the form — only 1 and 3
	// arguments are admitted, so a 2-argument call is a Type_Mismatch, never a
	// partial read of either form.
	err := typecheck_grid(
		"fn bad(size: Cell) -> [Cell] {\n" +
		"  return grid_cells(size, size)\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_grid_cells_mapper_form_still_types :: proc(t: ^testing.T) {
	// AC (mapper regression): the kept 3-arg mapper types unchanged beside the
	// canonical form — two Int dims and a fn(x, y) -> Cell builder yield [Cell]
	// (the examples/snake all_cells shape).
	err := typecheck_grid(
		"fn all_cells() -> [Cell] {\n" +
		"  return grid_cells(2, 3, fn(x, y) { return Cell{x: x, y: y} })\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_grid_cells_canonical_evaluates_row_major :: proc(t: ^testing.T) {
	// AC (evaluation): the canonical form enumerates Cell{x: 2, y: 2} as the
	// EXACT row-major cell list (0,0),(1,0),(0,1),(1,1) — y outer, x inner,
	// verified against the mapper form's loop order — and the two arities
	// enumerate identically, so migrating a call site never reorders cells.
	report, err := run_test_pipeline(GRID_HEADER +
		"test \"canonical grid_cells walks row-major, y outer\" {\n" +
		"  assert grid_cells(Cell{x: 2, y: 2}) == [Cell{x: 0, y: 0}, Cell{x: 1, y: 0}, Cell{x: 0, y: 1}, Cell{x: 1, y: 1}]\n" +
		"  assert grid_cells(Cell{x: 2, y: 2}) == grid_cells(2, 2, fn(x, y) { return Cell{x: x, y: y} })\n" +
		"  assert grid_cells(Cell{x: 0, y: 3}) == []\n" +
		"}\n")
	testing.expect_value(t, err, Pipeline_Error.None)
	// passed counts ASSERTS (the golden-count discipline): all three pins hold.
	testing.expect_value(t, report.passed, 3)
	testing.expect_value(t, report.failed, 0)
	testing.expect_value(t, report.exit_code, 0)
}

// ── The completed §26 engine.grid row: imported Cell + neighbors/in_bounds ──

// GRID_IMPORT_HEADER imports the WHOLE §26 engine.grid row — the structural
// Cell record INSTEAD of a local declaration (the dungeon's import line) plus
// the two adjacency helpers.
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
	// AC (the structural admission): the IMPORTED Cell serves every position a
	// user-declared one does — a top-level let annotation, construction,
	// field projection into Int arithmetic, equality, and the grid_cells
	// cell-shape judgment — with no engine ground minted (the dungeon's
	// MAP_SIZE/step_cell spellings, verbatim shapes).
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
	// AC (§02 one name, one meaning): importing engine.grid's Cell AND
	// declaring a local `data Cell` is the same Name_Collision any
	// import-shadowing declaration is — the structural admission adds no
	// second namespace.
	err := typecheck_grid_import("data Cell { x: Int, y: Int }\n")
	testing.expect_value(t, err, Type_Error.Name_Collision)
}

@(test)
test_neighbors_in_bounds_type_and_reject :: proc(t: ^testing.T) {
	// AC (helper typing): neighbors(cell) yields a list folding back into
	// cell positions, in_bounds(cell, size) yields the Bool gate — and each
	// rejects a non-cell argument and a wrong arity with the named
	// Type_Mismatch, never a silent admit.
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
	// AC (evaluation, exact pins): neighbors enumerates the four orthogonal
	// cells in row-major reading order — above, left, right, below (the
	// grid_cells y-outer order applied to adjacency) — and in_bounds answers
	// the [0, size) verdict on the interior, every edge, and both overflow
	// sides.
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
	// passed counts ASSERTS: the order pin plus the six bounds verdicts.
	testing.expect_value(t, report.passed, 7)
	testing.expect_value(t, report.failed, 0)
	testing.expect_value(t, report.exit_code, 0)
}

@(test)
test_imported_cell_rides_tilemap_queries :: proc(t: ^testing.T) {
	// AC (the dungeon's seam): the IMPORTED Cell flows through the §18 §4
	// fixture queries — cell_of echoes the imported record type back, so the
	// movement-gate composition types and evaluates without a local Cell
	// declaration (the SETTILE_HEADER's local-record form stays valid beside
	// this, pinned in settile_command_test).
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
