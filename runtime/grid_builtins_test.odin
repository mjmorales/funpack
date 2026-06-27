package funpack_runtime

import "core:testing"

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
	context.allocator = context.temp_allocator
	interp := gb_interp()

	scope := gb_scope("here", gb_cell("Cell", 5, 3))
	node := gb_call_node("neighbors", gb_name_node("here"))
	result, ok := eval(&interp, &node, &scope)
	testing.expect(t, ok)
	list, is_list := result.(List_Value)
	testing.expect(t, is_list)
	if !is_list || !testing.expect_value(t, len(list.elements), 4) {
		return
	}
	gb_expect_cell(t, list.elements[0], "Cell", 5, 2)
	gb_expect_cell(t, list.elements[1], "Cell", 4, 3)
	gb_expect_cell(t, list.elements[2], "Cell", 6, 3)
	gb_expect_cell(t, list.elements[3], "Cell", 5, 4)

	alias_scope := gb_scope("here", gb_cell("GridPos", 0, 0))
	alias_node := gb_call_node("neighbors", gb_name_node("here"))
	alias_result, alias_ok := eval(&interp, &alias_node, &alias_scope)
	testing.expect(t, alias_ok)
	alias_list := alias_result.(List_Value)
	gb_expect_cell(t, alias_list.elements[0], "GridPos", 0, -1)

	bad_scope := gb_scope("here", Fixed(0))
	bad_node := gb_call_node("neighbors", gb_name_node("here"))
	_, bad_ok := eval(&interp, &bad_node, &bad_scope)
	testing.expect_value(t, bad_ok, false)

	size := gb_cell("Cell", 16, 9)
	in_bounds_cases := [](struct {
		x, y:     i64,
		expected: bool,
	}) {
		{0, 0, true},
		{15, 8, true},
		{16, 8, false},
		{15, 9, false},
		{-1, 0, false},
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

	bad_scope := gb_scope("opt", Fixed(0), "fb", Value(Fixed(0)))
	bad_node := gb_call_node("or_else", gb_name_node("opt"), gb_name_node("fb"))
	_, bad_ok := eval(&interp, &bad_node, &bad_scope)
	testing.expect_value(t, bad_ok, false)
}

@(test)
test_grid_is_some_reports_presence :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	interp := gb_interp()

	payload := new(Value, context.temp_allocator)
	payload^ = Fixed(7 << 32)
	some := Variant_Value{enum_type = "Option", case_name = "Some", payload = payload}
	some_scope := gb_scope("opt", some)
	some_node := gb_call_node("is_some", gb_name_node("opt"))
	got, ok := eval(&interp, &some_node, &some_scope)
	testing.expect(t, ok)
	testing.expect_value(t, got.(bool), true)

	none := Variant_Value{enum_type = "Option", case_name = "None"}
	none_scope := gb_scope("opt", none)
	none_node := gb_call_node("is_some", gb_name_node("opt"))
	absent, none_ok := eval(&interp, &none_node, &none_scope)
	testing.expect(t, none_ok)
	testing.expect_value(t, absent.(bool), false)

	bad_scope := gb_scope("opt", Fixed(0))
	bad_node := gb_call_node("is_some", gb_name_node("opt"))
	_, bad_ok := eval(&interp, &bad_node, &bad_scope)
	testing.expect_value(t, bad_ok, false)
}
