// Fixture proof for the §18 §4 stdlib engine.grid combinators `neighbors(cell)`
// and `in_bounds(cell, size)` — the open-neighbor gate the dungeon's ooze AI
// folds (filter(neighbors(here), c => in_bounds(c, MAP_SIZE) and enterable(…))),
// plus the §26 prelude unwrap `or_else` its hero_pos ends on. Each builtin is
// evaluated over a hand-built Record_Value fixture and a synthetic call node
// (the interp_combinators_test mold), then pinned to its EXACT expected output,
// mirroring the funpack evaluator arms bit-for-bit (evaluate.odin
// eval_neighbors / eval_in_bounds / eval_or_else): neighbor order is the
// documented ROW-MAJOR READING ORDER — above, left, right, below — never a map
// iteration order, so a fold over the open set is deterministic by
// construction.
package funpack_runtime

import "core:testing"

// gb_name_node / gb_call_node mirror interp_combinators_test's synthetic-node
// builders (private to that file, so re-stated here): a `name N` reference arg
// and a `call` node whose child[0] is the callee name.
@(private = "file")
gb_name_node :: proc(name: string) -> Node {
	fields := make([]string, 1, context.temp_allocator)
	fields[0] = name
	return Node{kind = .Name, fields = fields}
}

@(private = "file")
gb_call_node :: proc(callee: string, args: ..Node) -> Node {
	children := make([]Node, len(args) + 1, context.temp_allocator)
	children[0] = gb_name_node(callee)
	for arg, i in args {
		children[i + 1] = arg
	}
	return Node{kind = .Call, children = children}
}

@(private = "file")
gb_interp :: proc() -> Interp {
	program := new(Program, context.temp_allocator)
	return Interp{program = program, allocator = context.temp_allocator}
}

// gb_cell builds a {x, y} record of the given type name — `type_name` is
// load-bearing: neighbors must echo the ARGUMENT's own record type onto its
// elements (the grid_cells discipline), so the fixture varies it.
@(private = "file")
gb_cell :: proc(type_name: string, x, y: i64) -> Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["x"] = x
	fields["y"] = y
	return Record_Value{type_name = type_name, fields = fields}
}

@(private = "file")
gb_scope :: proc(n1: string, v1: Value, n2: string = "", v2: Value = nil) -> Env {
	names := make(map[string]Value, context.temp_allocator)
	names[n1] = v1
	if n2 != "" {
		names[n2] = v2
	}
	return Env{names = names}
}

@(private = "file")
gb_expect_cell :: proc(t: ^testing.T, v: Value, type_name: string, x, y: i64) {
	r, ok := v.(Record_Value)
	testing.expect(t, ok)
	if !ok {
		return
	}
	testing.expect_value(t, r.type_name, type_name)
	testing.expect_value(t, r.fields["x"].(i64), x)
	testing.expect_value(t, r.fields["y"].(i64), y)
}

@(test)
test_grid :: proc(t: ^testing.T) {
	// AC (the §18 §4 grid combinators, exact pins): neighbors(Cell{5,3}) is
	// EXACTLY [(5,2), (4,3), (6,3), (5,4)] — above, left, right, below, the
	// row-major reading order the funpack evaluator pins — with every element
	// carrying the argument's own record type; in_bounds answers the closed
	// [0, size.x) × [0, size.y) half-open box over the dungeon's 16×9 MAP_SIZE,
	// pinned at all four rails (inside corners true, each overflow arm false).
	context.allocator = context.temp_allocator
	interp := gb_interp()

	// --- neighbors: order + coordinates + the echoed element type ---
	scope := gb_scope("here", gb_cell("Cell", 5, 3))
	node := gb_call_node("neighbors", gb_name_node("here"))
	result, ok := eval(&interp, &node, &scope)
	testing.expect(t, ok)
	list, is_list := result.(List_Value)
	testing.expect(t, is_list)
	if !is_list || !testing.expect_value(t, len(list.elements), 4) {
		return
	}
	gb_expect_cell(t, list.elements[0], "Cell", 5, 2) // above: (x, y-1)
	gb_expect_cell(t, list.elements[1], "Cell", 4, 3) // left:  (x-1, y)
	gb_expect_cell(t, list.elements[2], "Cell", 6, 3) // right: (x+1, y)
	gb_expect_cell(t, list.elements[3], "Cell", 5, 4) // below: (x, y+1)

	// The element type echoes the ARGUMENT's record type, not a hardwired
	// "Cell" — a GridPos-typed cell yields GridPos neighbors.
	alias_scope := gb_scope("here", gb_cell("GridPos", 0, 0))
	alias_node := gb_call_node("neighbors", gb_name_node("here"))
	alias_result, alias_ok := eval(&interp, &alias_node, &alias_scope)
	testing.expect(t, alias_ok)
	alias_list := alias_result.(List_Value)
	gb_expect_cell(t, alias_list.elements[0], "GridPos", 0, -1)

	// A non-cell argument fails closed — never a guessed neighborhood.
	bad_scope := gb_scope("here", Fixed(0))
	bad_node := gb_call_node("neighbors", gb_name_node("here"))
	_, bad_ok := eval(&interp, &bad_node, &bad_scope)
	testing.expect_value(t, bad_ok, false)

	// --- in_bounds over the dungeon's MAP_SIZE = Cell{16, 9} ---
	size := gb_cell("Cell", 16, 9)
	in_bounds_cases := [](struct {
		x, y:     i64,
		expected: bool,
	}) {
		{0, 0, true}, // the top-left corner is inside
		{15, 8, true}, // the bottom-right corner is the last inside cell
		{16, 8, false}, // x == size.x is one past the half-open box
		{15, 9, false}, // y == size.y likewise
		{-1, 0, false}, // a negative coordinate is outside on either axis
		{0, -1, false},
	}
	for tc in in_bounds_cases {
		case_scope := gb_scope("c", gb_cell("Cell", tc.x, tc.y), "size", size)
		case_node := gb_call_node("in_bounds", gb_name_node("c"), gb_name_node("size"))
		verdict, case_ok := eval(&interp, &case_node, &case_scope)
		testing.expect(t, case_ok)
		testing.expect_value(t, verdict.(bool), tc.expected)
	}
}

@(test)
test_grid_or_else_unwraps_lazily :: proc(t: ^testing.T) {
	// or_else(Some(v), fallback) is v; or_else(None, fallback) is the fallback —
	// and the fallback expression evaluates ONLY on the None arm (the funpack
	// eval_or_else contract): over a Some, a fallback naming an UNBOUND local
	// still succeeds, proving it never ran.
	context.allocator = context.temp_allocator
	interp := gb_interp()

	payload := new(Value, context.temp_allocator)
	payload^ = Fixed(7 << 32)
	some := Variant_Value{enum_type = "Option", case_name = "Some", payload = payload}
	some_scope := gb_scope("opt", some)
	some_node := gb_call_node("or_else", gb_name_node("opt"), gb_name_node("never_bound"))
	got, ok := eval(&interp, &some_node, &some_scope)
	testing.expect(t, ok)
	testing.expect_value(t, got.(Fixed), Fixed(7 << 32))

	none := Variant_Value{enum_type = "Option", case_name = "None"}
	none_scope := gb_scope("opt", none, "fb", Value(Fixed(3 << 32)))
	none_node := gb_call_node("or_else", gb_name_node("opt"), gb_name_node("fb"))
	fell, none_ok := eval(&interp, &none_node, &none_scope)
	testing.expect(t, none_ok)
	testing.expect_value(t, fell.(Fixed), Fixed(3 << 32))

	// A non-Option first argument fails closed.
	bad_scope := gb_scope("opt", Fixed(0), "fb", Value(Fixed(0)))
	bad_node := gb_call_node("or_else", gb_name_node("opt"), gb_name_node("fb"))
	_, bad_ok := eval(&interp, &bad_node, &bad_scope)
	testing.expect_value(t, bad_ok, false)
}
