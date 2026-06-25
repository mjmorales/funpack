// Fixture proof for the §08 list combinators and the §26 engine.grid.grid_cells
// — the leaf evaluator surface snake's free-cell selection, body stepping, and
// signal gating fold through (cells/body_after/occupied/all_cells/detect_eat).
// The snake artifact does not exist yet, so each combinator is evaluated over a
// hand-built List_Value/Record_Value fixture and a small synthetic node forest
// (a `call` node over Name args plus inline lambda nodes), then pinned to its
// EXACT expected output. grid_cells is forced to its documented stable row-major
// order so the cell list is machine-identical, independent of any map iteration.
package funpack_runtime

import "core:testing"

// --- synthetic-node builders ----------------------------------------------

// name_node builds a `name N` reference node — the arg shape the combinator
// tests resolve from a seeded scope (mirrors interp_test's call helpers, where
// runtime values arrive as named bindings rather than literals).
@(private = "file")
name_node :: proc(name: string) -> Node {
	fields := make([]string, 1, context.temp_allocator)
	fields[0] = name
	return Node{kind = .Name, fields = fields}
}

// field_node builds a `recv.FIELD` read node over a single receiver child — the
// projection a map/filter lambda body performs (snake's `f => f.cell`).
@(private = "file")
field_node :: proc(field: string, recv: Node) -> Node {
	fields := make([]string, 1, context.temp_allocator)
	fields[0] = field
	children := make([]Node, 1, context.temp_allocator)
	children[0] = recv
	return Node{kind = .Field, fields = fields, children = children}
}

// record_node builds a `record TYPE` literal node from recfield (name, value)
// children — the constructor a grid_cells lambda body returns (`fn(x, y) =>
// Cell{x: x, y: y}`).
@(private = "file")
record_node :: proc(type_name: string, fields_in: ..struct {
		name: string,
		val:  Node,
	}) -> Node {
	scalars := make([]string, 1, context.temp_allocator)
	scalars[0] = type_name
	children := make([]Node, len(fields_in), context.temp_allocator)
	for f, i in fields_in {
		recfield_scalars := make([]string, 1, context.temp_allocator)
		recfield_scalars[0] = f.name
		recfield_children := make([]Node, 1, context.temp_allocator)
		recfield_children[0] = f.val
		children[i] = Node {
			kind     = .Recfield,
			fields   = recfield_scalars,
			children = recfield_children,
		}
	}
	return Node{kind = .Record, fields = scalars, children = children}
}

// lambda_node builds a `lambda PARAM_COUNT PARAM…` closure node over a body
// child — a unary `f => body` or a binary `fn(x, y) => body`. eval_lambda reads
// fields[0] as the count and fields[1:] as the binder names.
@(private = "file")
lambda_node :: proc(body: Node, params: ..string) -> Node {
	fields := make([]string, len(params) + 1, context.temp_allocator)
	fields[0] = encode_count(len(params))
	for p, i in params {
		fields[i + 1] = p
	}
	children := make([]Node, 1, context.temp_allocator)
	children[0] = body
	return Node{kind = .Lambda, fields = fields, children = children}
}

// encode_count renders a small non-negative count to its decimal token (a node
// line carries counts as text).
@(private = "file")
encode_count :: proc(n: int) -> string {
	return aprint_int(i64(n), context.temp_allocator)
}

// call_node builds a `call` node: child[0] is the callee `name` (the dispatcher
// resolved it already, so the value is unused), children[1:] are the arg nodes
// the builtin reads positionally.
@(private = "file")
call_node :: proc(callee: string, args: ..Node) -> Node {
	children := make([]Node, len(args) + 1, context.temp_allocator)
	children[0] = name_node(callee)
	for arg, i in args {
		children[i + 1] = arg
	}
	return Node{kind = .Call, children = children}
}

// --- fixture builders -----------------------------------------------------

// bare_interp builds a program-less interpreter over the test temp allocator —
// the combinators are leaf evaluators that never reach a user §9 helper or a
// resource, so an empty program suffices.
@(private = "file")
bare_interp :: proc() -> Interp {
	program := new(Program, context.temp_allocator)
	return Interp{program = program, allocator = context.temp_allocator}
}

// cell builds a Cell record value {x, y} — the §26 grid cell snake's combinators
// range over. A Cell is a plain `data` record, so equality is structural.
@(private = "file")
cell :: proc(x, y: i64) -> Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["x"] = x
	fields["y"] = y
	return Record_Value{type_name = "Cell", fields = fields}
}

// cell_list builds a List_Value of Cell records — a hand-built `[Cell]` the
// combinator under test folds over.
@(private = "file")
cell_list :: proc(cells: ..Value) -> Value {
	elems := make([]Value, len(cells), context.temp_allocator)
	for c, i in cells {
		elems[i] = c
	}
	return List_Value{elements = elems}
}

// scope1 / scope2 / scope3 seed an environment with named bindings the call
// node's Name args resolve from.
@(private = "file")
scope1 :: proc(n1: string, v1: Value) -> Env {
	names := make(map[string]Value, context.temp_allocator)
	names[n1] = v1
	return Env{names = names}
}

@(private = "file")
scope2 :: proc(n1: string, v1: Value, n2: string, v2: Value) -> Env {
	names := make(map[string]Value, context.temp_allocator)
	names[n1] = v1
	names[n2] = v2
	return Env{names = names}
}

// as_cells reads a result Value as its Cell-record slice for elementwise
// assertion; a non-list result returns an empty slice so a failing test reads a
// length mismatch rather than panicking.
@(private = "file")
as_cells :: proc(v: Value) -> []Value {
	list, ok := v.(List_Value)
	if !ok {
		return {}
	}
	return list.elements
}

// expect_cell asserts a result element is the Cell {x, y}.
@(private = "file")
expect_cell :: proc(t: ^testing.T, v: Value, x, y: i64) {
	r, ok := v.(Record_Value)
	testing.expect(t, ok)
	if !ok {
		return
	}
	testing.expect_value(t, r.fields["x"].(i64), x)
	testing.expect_value(t, r.fields["y"].(i64), y)
}

// --- list combinator fixtures ---------------------------------------------

// prepend(elem, list) puts the element at the front, then the list in order —
// snake's cells() prepends the head onto the body.
@(test)
test_combinator_prepend :: proc(t: ^testing.T) {
	interp := bare_interp()
	env := scope2("head", cell(10, 10), "body", cell_list(cell(9, 10), cell(8, 10)))
	node := call_node("prepend", name_node("head"), name_node("body"))

	result, ok := builtin_prepend(&interp, &node, &env)
	testing.expect(t, ok)
	out := as_cells(result)
	testing.expect_value(t, len(out), 3)
	expect_cell(t, out[0], 10, 10)
	expect_cell(t, out[1], 9, 10)
	expect_cell(t, out[2], 8, 10)
}

// prepend onto the empty list yields a one-element list — the body_after edge a
// fresh snake hits before any growth.
@(test)
test_combinator_prepend_onto_empty :: proc(t: ^testing.T) {
	interp := bare_interp()
	env := scope2("head", cell(5, 5), "body", cell_list())
	node := call_node("prepend", name_node("head"), name_node("body"))

	result, ok := builtin_prepend(&interp, &node, &env)
	testing.expect(t, ok)
	out := as_cells(result)
	testing.expect_value(t, len(out), 1)
	expect_cell(t, out[0], 5, 5)
}

// init(list) drops the last element — snake's body_after trims the tail when the
// snake is not growing.
@(test)
test_combinator_init :: proc(t: ^testing.T) {
	interp := bare_interp()
	env := scope1("body", cell_list(cell(1, 1), cell(2, 2), cell(3, 3)))
	node := call_node("init", name_node("body"))

	result, ok := builtin_init(&interp, &node, &env)
	testing.expect(t, ok)
	out := as_cells(result)
	testing.expect_value(t, len(out), 2)
	expect_cell(t, out[0], 1, 1)
	expect_cell(t, out[1], 2, 2)
}

// init(empty) is the empty list — the edge case: dropping the last of nothing is
// total, never a fault (§26 totality).
@(test)
test_combinator_init_empty :: proc(t: ^testing.T) {
	interp := bare_interp()
	env := scope1("body", cell_list())
	node := call_node("init", name_node("body"))

	result, ok := builtin_init(&interp, &node, &env)
	testing.expect(t, ok)
	testing.expect_value(t, len(as_cells(result)), 0)
}

// contains(list, elem) is structural membership over Cell records — snake tests
// `contains(self.body, self.head)` for self-collision. Present and absent are
// both forced; the present case proves deep record equality (not pointer
// identity), the absent case proves a near-miss cell is not a member.
@(test)
test_combinator_contains :: proc(t: ^testing.T) {
	interp := bare_interp()
	body := cell_list(cell(1, 1), cell(2, 2), cell(3, 3))

	present_env := scope2("body", body, "head", cell(2, 2))
	present_node := call_node("contains", name_node("body"), name_node("head"))
	present, present_ok := builtin_contains(&interp, &present_node, &present_env)
	testing.expect(t, present_ok)
	testing.expect_value(t, present.(bool), true)

	absent_env := scope2("body", body, "head", cell(2, 3))
	absent_node := call_node("contains", name_node("body"), name_node("head"))
	absent, absent_ok := builtin_contains(&interp, &absent_node, &absent_env)
	testing.expect(t, absent_ok)
	testing.expect_value(t, absent.(bool), false)
}

// contains over the empty list is always false (totality).
@(test)
test_combinator_contains_empty :: proc(t: ^testing.T) {
	interp := bare_interp()
	env := scope2("occ", cell_list(), "c", cell(0, 0))
	node := call_node("contains", name_node("occ"), name_node("c"))

	result, ok := builtin_contains(&interp, &node, &env)
	testing.expect(t, ok)
	testing.expect_value(t, result.(bool), false)
}

// is_empty(list) gates snake's grow/replenish/apply_death on an empty signal
// list — true for [], false for a populated list.
@(test)
test_combinator_is_empty :: proc(t: ^testing.T) {
	interp := bare_interp()

	empty_env := scope1("eaten", cell_list())
	empty_node := call_node("is_empty", name_node("eaten"))
	empty_result, empty_ok := builtin_is_empty(&interp, &empty_node, &empty_env)
	testing.expect(t, empty_ok)
	testing.expect_value(t, empty_result.(bool), true)

	full_env := scope1("eaten", cell_list(cell(0, 0)))
	full_node := call_node("is_empty", name_node("eaten"))
	full_result, full_ok := builtin_is_empty(&interp, &full_node, &full_env)
	testing.expect(t, full_ok)
	testing.expect_value(t, full_result.(bool), false)
}

// concat(a, b) joins two lists end to end in order — snake's occupied()
// concatenates the snake's cells with the food cells.
@(test)
test_combinator_concat :: proc(t: ^testing.T) {
	interp := bare_interp()
	env := scope2("a", cell_list(cell(0, 0), cell(1, 0)), "b", cell_list(cell(5, 5)))
	node := call_node("concat", name_node("a"), name_node("b"))

	result, ok := builtin_concat(&interp, &node, &env)
	testing.expect(t, ok)
	out := as_cells(result)
	testing.expect_value(t, len(out), 3)
	expect_cell(t, out[0], 0, 0)
	expect_cell(t, out[1], 1, 0)
	expect_cell(t, out[2], 5, 5)
}

// map(list, fn) projects each element through a unary lambda, preserving order —
// snake projects food rows to their cells (`f => f.cell`). The lambda body reads
// `c.x` here and rebuilds a Cell shifted, proving the projection runs per element
// and the result order matches the input.
@(test)
test_combinator_map :: proc(t: ^testing.T) {
	interp := bare_interp()
	env := scope1("cells", cell_list(cell(1, 2), cell(3, 4)))
	// fn(c) => Cell{x: c.x, y: c.y}  — identity over the cell fields.
	body := record_node(
		"Cell",
		{name = "x", val = field_node("x", name_node("c"))},
		{name = "y", val = field_node("y", name_node("c"))},
	)
	lam := lambda_node(body, "c")
	node := call_node("map", name_node("cells"), lam)

	result, ok := builtin_map(&interp, &node, &env)
	testing.expect(t, ok)
	out := as_cells(result)
	testing.expect_value(t, len(out), 2)
	expect_cell(t, out[0], 1, 2)
	expect_cell(t, out[1], 3, 4)
}

// filter(list, pred) keeps the elements the predicate accepts, in order — snake
// filters foods by the head cell and all_cells by un-occupied. The predicate
// `c => c.x == self.head.x` (here a fixed target via a captured binding) keeps
// only the matching cells; the kept order is the input order.
@(test)
test_combinator_filter :: proc(t: ^testing.T) {
	interp := bare_interp()
	// `c => c.x == target` where target=2 is captured from the enclosing scope.
	env := scope2("cells", cell_list(cell(1, 0), cell(2, 0), cell(2, 9), cell(3, 0)), "target", i64(2))
	pred_body := Node {
		kind     = .Binary,
		fields   = bin_fields("eq"),
		children = bin_children(field_node("x", name_node("c")), name_node("target")),
	}
	lam := lambda_node(pred_body, "c")
	node := call_node("filter", name_node("cells"), lam)

	result, ok := builtin_filter(&interp, &node, &env)
	testing.expect(t, ok)
	out := as_cells(result)
	testing.expect_value(t, len(out), 2)
	expect_cell(t, out[0], 2, 0)
	expect_cell(t, out[1], 2, 9)
}

// filter that keeps nothing yields the empty list.
@(test)
test_combinator_filter_none :: proc(t: ^testing.T) {
	interp := bare_interp()
	env := scope2("cells", cell_list(cell(1, 0), cell(3, 0)), "target", i64(2))
	pred_body := Node {
		kind     = .Binary,
		fields   = bin_fields("eq"),
		children = bin_children(field_node("x", name_node("c")), name_node("target")),
	}
	lam := lambda_node(pred_body, "c")
	node := call_node("filter", name_node("cells"), lam)

	result, ok := builtin_filter(&interp, &node, &env)
	testing.expect(t, ok)
	testing.expect_value(t, len(as_cells(result)), 0)
}

// find(list, pred) is first's mandatory-predicate form — the first element the
// predicate accepts as Some, else None. Driven through eval_named_call so the
// "find" dispatch case (which lowers to builtin_first) is the junction under
// test: the gameplay-eval twin of the compiler's eval_find — both evaluators must
// admit find in lockstep or gameplay silently drops it.
@(test)
test_combinator_find :: proc(t: ^testing.T) {
	interp := bare_interp()
	// `c => c.x == target` with target=2: the first matching cell is (2, 0).
	env := scope2("cells", cell_list(cell(1, 0), cell(2, 0), cell(2, 9)), "target", i64(2))
	pred_body := Node {
		kind     = .Binary,
		fields   = bin_fields("eq"),
		children = bin_children(field_node("x", name_node("c")), name_node("target")),
	}
	lam := lambda_node(pred_body, "c")
	node := call_node("find", name_node("cells"), lam)

	result, ok := eval_named_call(&interp, "find", &node, &env)
	testing.expect(t, ok)
	some, is_some := result.(Variant_Value)
	testing.expect(t, is_some)
	testing.expect_value(t, some.case_name, "Some")
	expect_cell(t, some.payload^, 2, 0)
}

// find that matches nothing yields Option::None (never a fault).
@(test)
test_combinator_find_none :: proc(t: ^testing.T) {
	interp := bare_interp()
	env := scope2("cells", cell_list(cell(1, 0), cell(3, 0)), "target", i64(2))
	pred_body := Node {
		kind     = .Binary,
		fields   = bin_fields("eq"),
		children = bin_children(field_node("x", name_node("c")), name_node("target")),
	}
	lam := lambda_node(pred_body, "c")
	node := call_node("find", name_node("cells"), lam)

	result, ok := eval_named_call(&interp, "find", &node, &env)
	testing.expect(t, ok)
	none_variant, is_variant := result.(Variant_Value)
	testing.expect(t, is_variant)
	testing.expect_value(t, none_variant.case_name, "None")
}

// bin_fields / bin_children build a `binary OP` node's parts for the predicate
// lambdas (an `eq` over a field read and a captured target).
@(private = "file")
bin_fields :: proc(op: string) -> []string {
	fields := make([]string, 1, context.temp_allocator)
	fields[0] = op
	return fields
}

@(private = "file")
bin_children :: proc(lhs, rhs: Node) -> []Node {
	children := make([]Node, 2, context.temp_allocator)
	children[0] = lhs
	children[1] = rhs
	return children
}

// --- grid_cells fixtures --------------------------------------------------

// grid_cells(2, 3, fn(x, y) => Cell{x, y}) yields the six cells in the documented
// stable ROW-MAJOR order: row 0 left-to-right, then row 1, then row 2. The order
// is driven by the loop indices, never by any map/hash iteration, so the list is
// machine-identical on every run.
@(test)
test_grid_cells_row_major_order :: proc(t: ^testing.T) {
	interp := bare_interp()
	env := scope2("w", i64(2), "h", i64(3))
	// fn(x, y) => Cell{x: x, y: y}
	body := record_node(
		"Cell",
		{name = "x", val = name_node("x")},
		{name = "y", val = name_node("y")},
	)
	lam := lambda_node(body, "x", "y")
	node := call_node("grid_cells", name_node("w"), name_node("h"), lam)

	result, ok := builtin_grid_cells(&interp, &node, &env)
	testing.expect(t, ok)
	out := as_cells(result)
	testing.expect_value(t, len(out), 6)
	// Documented row-major order for a 2×3 grid (w=2, h=3): (x, y) with y outer.
	expect_cell(t, out[0], 0, 0)
	expect_cell(t, out[1], 1, 0)
	expect_cell(t, out[2], 0, 1)
	expect_cell(t, out[3], 1, 1)
	expect_cell(t, out[4], 0, 2)
	expect_cell(t, out[5], 1, 2)
}

// grid_cells on a degenerate (zero-extent) grid is the empty list — total, never
// a fault on a non-positive dimension.
@(test)
test_grid_cells_degenerate :: proc(t: ^testing.T) {
	interp := bare_interp()
	env := scope2("w", i64(0), "h", i64(4))
	body := record_node(
		"Cell",
		{name = "x", val = name_node("x")},
		{name = "y", val = name_node("y")},
	)
	lam := lambda_node(body, "x", "y")
	node := call_node("grid_cells", name_node("w"), name_node("h"), lam)

	result, ok := builtin_grid_cells(&interp, &node, &env)
	testing.expect(t, ok)
	testing.expect_value(t, len(as_cells(result)), 0)
}

// --- §08 View iteration + reference surface (gameplay eval) ----------------

// method_call_node builds a `recv.method(args)` call node — a `.Call` whose
// children[0] is a `.Field` callee (the method token over the receiver child) and
// children[1:] are the arg nodes. The dual of call_node (a bare `.Name` callee);
// eval_call routes a `.Field` callee to eval_method_call, where a List_Value
// receiver dispatches the §08 View surface (count/at/ref/resolve).
@(private = "file")
method_call_node :: proc(method: string, recv: Node, args: ..Node) -> Node {
	children := make([]Node, len(args) + 1, context.temp_allocator)
	children[0] = field_node(method, recv)
	for arg, i in args {
		children[i + 1] = arg
	}
	return Node{kind = .Call, children = children}
}

// switch_value builds a `Switch{on}` record — the §08 thing a View materializes
// over; the count/at gameplay-eval tests range over a hand-built list of these.
@(private = "file")
switch_value :: proc(on: bool) -> Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["on"] = on
	return Record_Value{type_name = "Switch", fields = fields}
}

// view.count() reads the row count of a materialized View (a List_Value) as an Int
// — the §08 iteration surface gameplay-eval junction (world.fun:24). A behavior
// body that called count() before this was wired silently dropped its write: the
// dual-interpreter parity trap, the runtime twin of funpack's eval_view_count.
@(test)
test_view_count_gameplay_eval :: proc(t: ^testing.T) {
	interp := bare_interp()
	view := List_Value{elements = []Value{switch_value(true), switch_value(false), switch_value(true)}}
	env := scope1("switches", view)
	node := method_call_node("count", name_node("switches"))

	result, ok := eval(&interp, &node, &env)
	testing.expect(t, ok)
	count, is_int := result.(i64)
	testing.expect(t, is_int)
	testing.expect_value(t, count, i64(3))
}

// view.at(i) reads the i-th matched thing in stable order as the bare element T —
// the §08 index surface (world.fun:27), distinct from ref/resolve (which yield a
// Ref / an Option). An out-of-range index is fail-closed (ok=false), never a
// faulted read. Mirrors funpack's eval_view_at.
@(test)
test_view_at_gameplay_eval :: proc(t: ^testing.T) {
	interp := bare_interp()
	view := List_Value{elements = []Value{switch_value(true), switch_value(false)}}
	env := scope1("switches", view)

	at0_node := method_call_node("at", name_node("switches"), em_int_lit(0))
	at0, ok0 := eval(&interp, &at0_node, &env)
	testing.expect(t, ok0)
	rec0, is_rec0 := at0.(Record_Value)
	testing.expect(t, is_rec0)
	testing.expect_value(t, rec0.fields["on"].(bool), true)

	at1_node := method_call_node("at", name_node("switches"), em_int_lit(1))
	at1, ok1 := eval(&interp, &at1_node, &env)
	testing.expect(t, ok1)
	rec1, _ := at1.(Record_Value)
	testing.expect_value(t, rec1.fields["on"].(bool), false)

	// An out-of-range index fails closed (ok=false) — never a faulted/garbage read.
	oob_node := method_call_node("at", name_node("switches"), em_int_lit(5))
	_, oob_ok := eval(&interp, &oob_node, &env)
	testing.expect(t, !oob_ok)
}

// view.ref(i) mints an index-keyed Ref record and view.resolve(ref) reads it back
// to Option::Some/None — the §08 reference surface gameplay-eval junction (the
// `gate: Ref[T]` round-trip). An out-of-range ref resolves to Option::None (a
// despawned referent), never a fault. Mirrors funpack's eval_view_ref/resolve.
@(test)
test_view_ref_resolve_gameplay_eval :: proc(t: ^testing.T) {
	interp := bare_interp()
	view := List_Value{elements = []Value{switch_value(true), switch_value(false)}}
	env := scope1("switches", view)

	// ref(1) → a Ref record carrying index 1.
	ref_node := method_call_node("ref", name_node("switches"), em_int_lit(1))
	ref_val, ref_ok := eval(&interp, &ref_node, &env)
	testing.expect(t, ref_ok)
	ref_rec, is_ref := ref_val.(Record_Value)
	testing.expect(t, is_ref)
	testing.expect_value(t, ref_rec.type_name, "Ref")
	testing.expect_value(t, ref_rec.fields["index"].(i64), i64(1))

	// resolve(ref) → Option::Some(Switch{on: false}) — the row at index 1.
	env2 := scope2("switches", view, "gate", ref_val)
	resolve_node := method_call_node("resolve", name_node("switches"), name_node("gate"))
	resolved, res_ok := eval(&interp, &resolve_node, &env2)
	testing.expect(t, res_ok)
	some, is_some := resolved.(Variant_Value)
	testing.expect(t, is_some)
	testing.expect_value(t, some.case_name, "Some")
	payload_rec, _ := some.payload^.(Record_Value)
	testing.expect_value(t, payload_rec.fields["on"].(bool), false)

	// An out-of-range Ref resolves to Option::None (a despawned referent).
	oob_ref := make(map[string]Value, context.temp_allocator)
	oob_ref["index"] = i64(9)
	env3 := scope2("switches", view, "gate", Record_Value{type_name = "Ref", fields = oob_ref})
	none_node := method_call_node("resolve", name_node("switches"), name_node("gate"))
	none_val, none_ok := eval(&interp, &none_node, &env3)
	testing.expect(t, none_ok)
	none_variant, _ := none_val.(Variant_Value)
	testing.expect_value(t, none_variant.case_name, "None")
}

// em_int_lit builds an `.Int` literal node carrying the decimal token — the index
// arg the at/ref calls read positionally.
@(private = "file")
em_int_lit :: proc(n: i64) -> Node {
	fields := make([]string, 1, context.temp_allocator)
	fields[0] = aprint_int(n, context.temp_allocator)
	return Node{kind = .Int, fields = fields}
}
