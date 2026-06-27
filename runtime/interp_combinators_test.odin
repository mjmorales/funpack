package funpack_runtime

import "core:testing"

@(private = "file")
name_node :: proc(name: string) -> Node {
	fields := make([]string, 1, context.temp_allocator)
	fields[0] = name
	return Node{kind = .Name, fields = fields}
}

@(private = "file")
field_node :: proc(field: string, recv: Node) -> Node {
	fields := make([]string, 1, context.temp_allocator)
	fields[0] = field
	children := make([]Node, 1, context.temp_allocator)
	children[0] = recv
	return Node{kind = .Field, fields = fields, children = children}
}

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

@(private = "file")
encode_count :: proc(n: int) -> string {
	return aprint_int(i64(n), context.temp_allocator)
}

@(private = "file")
call_node :: proc(callee: string, args: ..Node) -> Node {
	children := make([]Node, len(args) + 1, context.temp_allocator)
	children[0] = name_node(callee)
	for arg, i in args {
		children[i + 1] = arg
	}
	return Node{kind = .Call, children = children}
}

@(private = "file")
bare_interp :: proc() -> Interp {
	program := new(Program, context.temp_allocator)
	return Interp{program = program, allocator = context.temp_allocator}
}

@(private = "file")
cell :: proc(x, y: i64) -> Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["x"] = x
	fields["y"] = y
	return Record_Value{type_name = "Cell", fields = fields}
}

@(private = "file")
cell_list :: proc(cells: ..Value) -> Value {
	elems := make([]Value, len(cells), context.temp_allocator)
	for c, i in cells {
		elems[i] = c
	}
	return List_Value{elements = elems}
}

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

@(private = "file")
as_cells :: proc(v: Value) -> []Value {
	list, ok := v.(List_Value)
	if !ok {
		return {}
	}
	return list.elements
}

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

@(test)
test_combinator_init_empty :: proc(t: ^testing.T) {
	interp := bare_interp()
	env := scope1("body", cell_list())
	node := call_node("init", name_node("body"))

	result, ok := builtin_init(&interp, &node, &env)
	testing.expect(t, ok)
	testing.expect_value(t, len(as_cells(result)), 0)
}

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

@(test)
test_combinator_contains_empty :: proc(t: ^testing.T) {
	interp := bare_interp()
	env := scope2("occ", cell_list(), "c", cell(0, 0))
	node := call_node("contains", name_node("occ"), name_node("c"))

	result, ok := builtin_contains(&interp, &node, &env)
	testing.expect(t, ok)
	testing.expect_value(t, result.(bool), false)
}

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

@(test)
test_combinator_map :: proc(t: ^testing.T) {
	interp := bare_interp()
	env := scope1("cells", cell_list(cell(1, 2), cell(3, 4)))
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

@(test)
test_combinator_filter :: proc(t: ^testing.T) {
	interp := bare_interp()
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

@(test)
test_combinator_find :: proc(t: ^testing.T) {
	interp := bare_interp()
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

@(test)
test_combinator_append :: proc(t: ^testing.T) {
	interp := bare_interp()
	env := scope2("cells", cell_list(cell(1, 0), cell(2, 0)), "item", cell(9, 9))
	node := call_node("append", name_node("cells"), name_node("item"))

	result, ok := builtin_append(&interp, &node, &env)
	testing.expect(t, ok)
	out := as_cells(result)
	testing.expect_value(t, len(out), 3)
	expect_cell(t, out[0], 1, 0)
	expect_cell(t, out[2], 9, 9)
}

@(test)
test_combinator_reverse :: proc(t: ^testing.T) {
	interp := bare_interp()
	env := scope1("cells", cell_list(cell(1, 0), cell(2, 0), cell(3, 0)))
	node := call_node("reverse", name_node("cells"))

	result, ok := builtin_reverse(&interp, &node, &env)
	testing.expect(t, ok)
	out := as_cells(result)
	testing.expect_value(t, len(out), 3)
	expect_cell(t, out[0], 3, 0)
	expect_cell(t, out[2], 1, 0)
}

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

@(test)
test_grid_cells_row_major_order :: proc(t: ^testing.T) {
	interp := bare_interp()
	env := scope2("w", i64(2), "h", i64(3))
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
	expect_cell(t, out[0], 0, 0)
	expect_cell(t, out[1], 1, 0)
	expect_cell(t, out[2], 0, 1)
	expect_cell(t, out[3], 1, 1)
	expect_cell(t, out[4], 0, 2)
	expect_cell(t, out[5], 1, 2)
}

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

@(private = "file")
method_call_node :: proc(method: string, recv: Node, args: ..Node) -> Node {
	children := make([]Node, len(args) + 1, context.temp_allocator)
	children[0] = field_node(method, recv)
	for arg, i in args {
		children[i + 1] = arg
	}
	return Node{kind = .Call, children = children}
}

@(private = "file")
switch_value :: proc(on: bool) -> Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["on"] = on
	return Record_Value{type_name = "Switch", fields = fields}
}

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

	oob_node := method_call_node("at", name_node("switches"), em_int_lit(5))
	_, oob_ok := eval(&interp, &oob_node, &env)
	testing.expect(t, !oob_ok)
}

@(test)
test_view_ref_resolve_gameplay_eval :: proc(t: ^testing.T) {
	interp := bare_interp()
	view := List_Value{elements = []Value{switch_value(true), switch_value(false)}}
	env := scope1("switches", view)

	ref_node := method_call_node("ref", name_node("switches"), em_int_lit(1))
	ref_val, ref_ok := eval(&interp, &ref_node, &env)
	testing.expect(t, ref_ok)
	ref_rec, is_ref := ref_val.(Record_Value)
	testing.expect(t, is_ref)
	testing.expect_value(t, ref_rec.type_name, "Ref")
	testing.expect_value(t, ref_rec.fields["index"].(i64), i64(1))

	env2 := scope2("switches", view, "gate", ref_val)
	resolve_node := method_call_node("resolve", name_node("switches"), name_node("gate"))
	resolved, res_ok := eval(&interp, &resolve_node, &env2)
	testing.expect(t, res_ok)
	some, is_some := resolved.(Variant_Value)
	testing.expect(t, is_some)
	testing.expect_value(t, some.case_name, "Some")
	payload_rec, _ := some.payload^.(Record_Value)
	testing.expect_value(t, payload_rec.fields["on"].(bool), false)

	oob_ref := make(map[string]Value, context.temp_allocator)
	oob_ref["index"] = i64(9)
	env3 := scope2("switches", view, "gate", Record_Value{type_name = "Ref", fields = oob_ref})
	none_node := method_call_node("resolve", name_node("switches"), name_node("gate"))
	none_val, none_ok := eval(&interp, &none_node, &env3)
	testing.expect(t, none_ok)
	none_variant, _ := none_val.(Variant_Value)
	testing.expect_value(t, none_variant.case_name, "None")
}

@(private = "file")
em_int_lit :: proc(n: i64) -> Node {
	fields := make([]string, 1, context.temp_allocator)
	fields[0] = aprint_int(n, context.temp_allocator)
	return Node{kind = .Int, fields = fields}
}
