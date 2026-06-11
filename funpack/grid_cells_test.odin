// The §18 §4 grid_cells fixtures: the CANONICAL grid_cells(size: Cell) ->
// [Cell] form beside the kept non-idiomatic 3-arg mapper, both selected by
// arity off the one engine.grid Func row. Typing pins the cell-shape judgment
// (a user record of exactly {x: Int, y: Int}, never a name match) and the
// named rejects for a wrong argument type, a wrong shape, and a wrong arity;
// evaluation pins the EXACT row-major cell list (y outer, x inner — verified
// against the mapper form's loop) and that both arities enumerate identically.
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
