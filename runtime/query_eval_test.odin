package funpack_runtime

import "core:testing"

@(private = "file")
query_node_fields :: proc(tokens: ..string) -> []string {
	out := make([]string, len(tokens), context.temp_allocator)
	copy(out, tokens)
	return out
}

@(private = "file")
query_node_children :: proc(nodes: ..Node) -> []Node {
	out := make([]Node, len(nodes), context.temp_allocator)
	copy(out, nodes)
	return out
}

@(private = "file")
doubled_query :: proc() -> Query_Decl {
	two := Node{kind = .Fixed, fields = query_node_fields("8589934592")}
	r := Node{kind = .Name, fields = query_node_fields("r")}
	product := Node{kind = .Binary, fields = query_node_fields("mul"), children = query_node_children(r, two)}
	body := make([]Node, 1, context.temp_allocator)
	body[0] = Node{kind = .Return, children = query_node_children(product)}
	params := make([]Param_Decl, 1, context.temp_allocator)
	params[0] = Param_Decl{name = "r", type = "Fixed"}
	return Query_Decl{name = "doubled", params = params, return_type = "Fixed", body = body}
}

@(private = "file")
query_test_interp :: proc(program: ^Program, version: ^World_Version, tick: ^Tick_State) -> Interp {
	return new_interp(program, version, tick, Input{}, time_resource(60, context.temp_allocator), context.temp_allocator)
}

@(test)
test_query_call_dispatches_through_named_call :: proc(t: ^testing.T) {
	queries := make([]Query_Decl, 1, context.temp_allocator)
	queries[0] = doubled_query()
	program := Program {
		queries = queries,
	}
	version := World_Version{tick = 0}
	tick := new_tick_state(version, context.temp_allocator, context.temp_allocator)
	interp := query_test_interp(&program, &version, &tick)

	callee := Node{kind = .Name, fields = query_node_fields("doubled")}
	arg := Node{kind = .Fixed, fields = query_node_fields("12884901888")}
	call := Node{kind = .Call, children = query_node_children(callee, arg)}
	env := Env {
		names = make(map[string]Value, context.temp_allocator),
	}
	result, ok := eval(&interp, &call, &env)
	testing.expect_value(t, ok, true)
	got, is_fixed := result.(Fixed)
	testing.expect_value(t, is_fixed, true)
	testing.expect_value(t, got, to_fixed(6))
}

@(private = "file")
sum_marks_program :: proc(allocator := context.temp_allocator) -> Program {
	cfields := make([]Field_Decl, 1, allocator)
	cfields[0] = Field_Decl{name = "mark", type = "Int"}
	things := make([]Thing_Decl, 1, allocator)
	things[0] = Thing_Decl{name = "Counter", fields = cfields}

	acc := Node{kind = .Name, fields = query_node_fields("acc")}
	c := Node{kind = .Name, fields = query_node_fields("c")}
	c_mark := Node{kind = .Field, fields = query_node_fields("mark"), children = query_node_children(c)}
	sum := Node{kind = .Binary, fields = query_node_fields("add"), children = query_node_children(acc, c_mark)}
	add_body := make([]Node, 1, allocator)
	add_body[0] = Node{kind = .Return, children = query_node_children(sum)}
	add_params := make([]Param_Decl, 2, allocator)
	add_params[0] = Param_Decl{name = "acc", type = "Int"}
	add_params[1] = Param_Decl{name = "c", type = "Counter"}
	functions := make([]Function_Decl, 1, allocator)
	functions[0] = Function_Decl{name = "add_mark", kind = .Fn, params = add_params, body = add_body}

	all_counter := Node{kind = .All, fields = query_node_fields("Counter")}
	zero := Node{kind = .Int, fields = query_node_fields("0")}
	fold_call := Node {
		kind     = .Call,
		children = query_node_children(
			Node{kind = .Name, fields = query_node_fields("fold")},
			all_counter,
			zero,
			Node{kind = .Name, fields = query_node_fields("add_mark")},
		),
	}
	q_body := make([]Node, 1, allocator)
	q_body[0] = Node{kind = .Return, children = query_node_children(fold_call)}
	queries := make([]Query_Decl, 1, allocator)
	queries[0] = Query_Decl{name = "sum_marks", return_type = "Int", body = q_body}

	return Program{things = things, functions = functions, queries = queries}
}

@(private = "file")
counter_table :: proc(marks: []i64, allocator := context.temp_allocator) -> Tick_Table {
	rows := make([dynamic]Row, 0, len(marks), allocator)
	for mark, i in marks {
		row := Row{id = Id{raw = Thing_Id(i)}, fields = make(map[string]Field_Value, allocator)}
		row.fields["mark"] = Field_Value(i64(mark))
		append(&rows, row)
	}
	return Tick_Table{thing = "Counter", rows = rows}
}

@(test)
test_query_all_read_is_evolving_not_memoized :: proc(t: ^testing.T) {
	program := sum_marks_program(context.temp_allocator)
	version := World_Version{tick = 0}
	tick := new_tick_state(version, context.temp_allocator, context.temp_allocator)
	tables := make([]Tick_Table, 1, context.temp_allocator)
	tables[0] = counter_table({1, 2}, context.temp_allocator)
	tick.tables = tables

	interp := query_test_interp(&program, &version, &tick)
	query := &program.queries[0]
	no_args := make([]Value, 0, context.temp_allocator)

	first, first_ok := eval_query_values(&interp, query, no_args)
	testing.expect_value(t, first_ok, true)
	first_sum, first_is_int := first.(i64)
	testing.expect_value(t, first_is_int, true)
	testing.expect_value(t, first_sum, i64(3))

	tick.tables[0].rows[0].fields["mark"] = Field_Value(i64(10))

	second, second_ok := eval_query_values(&interp, query, no_args)
	testing.expect_value(t, second_ok, true)
	second_sum, second_is_int := second.(i64)
	testing.expect_value(t, second_is_int, true)
	testing.expect_value(t, second_sum, i64(12))
}

@(test)
test_spatial_within_nearest_first_id_tiebreak :: proc(t: ^testing.T) {
	version := index_test_version("Ball", {
		index_blackboard({"pos", Vec2{to_fixed(3), to_fixed(4)}}),
		index_blackboard({"pos", Vec2{to_fixed(6), to_fixed(8)}}),
		index_blackboard({"pos", Vec2{to_fixed(0), to_fixed(5)}}),
		index_blackboard({"pos", Vec2{to_fixed(20), to_fixed(0)}}),
	})
	program := index_test_program([]Index_Req{{kind = .Spatial, thing = "Ball", field = "pos"}})
	state := build_index_state(&program, &version, context.temp_allocator)

	origin := Field_Value(Vec2{to_fixed(0), to_fixed(0)})
	hits, ok := spatial_within(&state, "Ball", "pos", origin, to_fixed(10), context.temp_allocator)
	testing.expect_value(t, ok, true)
	testing.expect_value(t, len(hits), 3)
	testing.expect_value(t, hits[0], Spatial_Hit{id = Id{raw = 0}, distance = to_fixed(5)})
	testing.expect_value(t, hits[1], Spatial_Hit{id = Id{raw = 2}, distance = to_fixed(5)})
	testing.expect_value(t, hits[2], Spatial_Hit{id = Id{raw = 1}, distance = to_fixed(10)})
}

@(test)
test_spatial_vec3_keys_measure_in_three_lanes :: proc(t: ^testing.T) {
	version := index_test_version("Probe", {
		index_blackboard({"pos", Vec3{to_fixed(1), to_fixed(2), to_fixed(2)}}),
		index_blackboard({"pos", Vec3{to_fixed(9), to_fixed(0), to_fixed(0)}}),
	})
	program := index_test_program([]Index_Req{{kind = .Spatial, thing = "Probe", field = "pos"}})
	state := build_index_state(&program, &version, context.temp_allocator)

	origin := Field_Value(Vec3{to_fixed(0), to_fixed(0), to_fixed(0)})
	hits, ok := spatial_within(&state, "Probe", "pos", origin, to_fixed(3), context.temp_allocator)
	testing.expect_value(t, ok, true)
	testing.expect_value(t, len(hits), 1)
	testing.expect_value(t, hits[0], Spatial_Hit{id = Id{raw = 0}, distance = to_fixed(3)})
}

@(test)
test_spatial_fails_closed_without_a_defined_distance :: proc(t: ^testing.T) {
	version := index_test_version("Ball", {
		index_blackboard({"pos", Vec2{to_fixed(1), to_fixed(1)}}),
	})
	program := index_test_program([]Index_Req{{kind = .Spatial, thing = "Ball", field = "pos"}})
	state := build_index_state(&program, &version, context.temp_allocator)

	_, undeclared := spatial_within(&state, "Crate", "pos", Field_Value(Vec2{}), to_fixed(1), context.temp_allocator)
	testing.expect_value(t, undeclared, false)

	_, scalar_origin := spatial_within(&state, "Ball", "pos", Field_Value(i64(3)), to_fixed(1), context.temp_allocator)
	testing.expect_value(t, scalar_origin, false)

	_, mismatched := spatial_within(&state, "Ball", "pos", Field_Value(Vec3{}), to_fixed(1), context.temp_allocator)
	testing.expect_value(t, mismatched, false)
}
