// The §08 §3 query-evaluation contract: a call to a declared query dispatches
// through the named-call surface and folds its carried body as a pure read
// (exact-equality pins per form), the body's `all[T]` reads the tick's EVOLVING
// working table so a re-call within one tick reflects an intervening column
// write (never cached — one uniform read rule with a direct View[T]/all[T]
// read, ADR same-tick-query-reads-are-evolving), and the @spatial radius query
// answers nearest-first with fixed-point bounds and the stable-Id tiebreak,
// failing closed wherever the kernel defines no distance. Hand-built node
// forests and working tables per test — the interp_test / index_test molds.
package funpack_runtime

import "core:testing"

// query_node_fields / query_node_children heap-allocate a hand-built node's
// slices from the temp arena so a fixture node escapes its constructing frame
// (the interp_test mold, file-private there).
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

// doubled_query builds a §08 §3 value-parameter query by hand:
// `query doubled(r: Fixed) -> Fixed { return r * 2.0 }` as its carried forest.
@(private = "file")
doubled_query :: proc() -> Query_Decl {
	two := Node{kind = .Fixed, fields = query_node_fields("8589934592")} // 2.0 in Q32.32
	r := Node{kind = .Name, fields = query_node_fields("r")}
	product := Node{kind = .Binary, fields = query_node_fields("mul"), children = query_node_children(r, two)}
	body := make([]Node, 1, context.temp_allocator)
	body[0] = Node{kind = .Return, children = query_node_children(product)}
	params := make([]Param_Decl, 1, context.temp_allocator)
	params[0] = Param_Decl{name = "r", type = "Fixed"}
	return Query_Decl{name = "doubled", params = params, return_type = "Fixed", body = body}
}

// query_test_interp builds an Interp over a query-bearing program with a tick
// in flight, so a query body's `all[T]` reads the tick's working table. The
// version is the empty world; a fixture that needs working rows sets tick.tables.
@(private = "file")
query_test_interp :: proc(program: ^Program, version: ^World_Version, tick: ^Tick_State) -> Interp {
	return new_interp(program, version, tick, Input{}, time_resource(60, context.temp_allocator), context.temp_allocator)
}

@(test)
test_query_call_dispatches_through_named_call :: proc(t: ^testing.T) {
	// AC (query calls ride the call surface): a `doubled(3.0)` call node whose
	// callee names a declared query folds the carried body — exact equality on
	// the fixed-point result, through the same eval path a behavior body takes.
	queries := make([]Query_Decl, 1, context.temp_allocator)
	queries[0] = doubled_query()
	program := Program {
		queries = queries,
	}
	version := World_Version{tick = 0}
	tick := new_tick_state(version, context.temp_allocator, context.temp_allocator)
	interp := query_test_interp(&program, &version, &tick)

	callee := Node{kind = .Name, fields = query_node_fields("doubled")}
	arg := Node{kind = .Fixed, fields = query_node_fields("12884901888")} // 3.0
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

// sum_marks_program builds the §08 §3 evolving-read fixture by hand: a thing
// `Counter { mark: Int }`, a §9 helper `add_mark(acc, c) = acc + c.mark`, and a
// nullary query `sum_marks() -> Int { return fold(all[Counter], 0, add_mark) }`.
// The query reads the world through `all[Counter]`, so it observes the tick's
// working table — the evolving-column discriminator below mutates a row's mark
// between two calls and the second call must see it.
@(private = "file")
sum_marks_program :: proc(allocator := context.temp_allocator) -> Program {
	cfields := make([]Field_Decl, 1, allocator)
	cfields[0] = Field_Decl{name = "mark", type = "Int"}
	things := make([]Thing_Decl, 1, allocator)
	things[0] = Thing_Decl{name = "Counter", fields = cfields}

	// fn add_mark(acc: Int, c: Counter) -> Int { return acc + c.mark }
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

	// query sum_marks() -> Int { return fold(all[Counter], 0, add_mark) }
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

// counter_table builds a working Counter table with the given per-row mark
// values, Id-ascending — the mid-tick working rows the query's `all[Counter]`
// reads (the interp_view_of_type working-table path).
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
	// AC (§08 §3 evolving read, the within-tick contract): a query whose body
	// folds `all[Counter]` over the mark column, eval'd twice within ONE tick
	// with a mid-tick column write between, returns the EVOLVED value the second
	// time — a query reads the working table at the call point exactly as a
	// direct View[T]/all[T] read does, never a cached first-call value. A
	// within-tick memo would instead return the stale first sum — the behavior
	// this test rules out.
	program := sum_marks_program(context.temp_allocator)
	version := World_Version{tick = 0}
	tick := new_tick_state(version, context.temp_allocator, context.temp_allocator)
	tables := make([]Tick_Table, 1, context.temp_allocator)
	tables[0] = counter_table({1, 2}, context.temp_allocator) // marks 1, 2 → sum 3
	tick.tables = tables

	interp := query_test_interp(&program, &version, &tick)
	query := &program.queries[0]
	no_args := make([]Value, 0, context.temp_allocator)

	first, first_ok := eval_query_values(&interp, query, no_args)
	testing.expect_value(t, first_ok, true)
	first_sum, first_is_int := first.(i64)
	testing.expect_value(t, first_is_int, true)
	testing.expect_value(t, first_sum, i64(3))

	// A mid-tick column write evolves the working table in place (the same
	// fold_behavior_result does per instance) — row 0's mark 1 → 10.
	tick.tables[0].rows[0].fields["mark"] = Field_Value(i64(10))

	second, second_ok := eval_query_values(&interp, query, no_args)
	testing.expect_value(t, second_ok, true)
	second_sum, second_is_int := second.(i64)
	testing.expect_value(t, second_is_int, true)
	testing.expect_value(t, second_sum, i64(12)) // 10 + 2 — the evolved read; a within-tick memo would return the stale 3
}

@(test)
test_spatial_within_nearest_first_id_tiebreak :: proc(t: ^testing.T) {
	// AC (§08 §3 radius query, exact equality): hits inside the fixed-point
	// radius answer NEAREST-FIRST with kernel-exact distances — (3,4) and
	// (0,5) both at exactly 5.0 tie and break by stable Id, (6,8) at 10.0
	// rides the inclusive bound, (20,0) is outside.
	version := index_test_version("Ball", {
		index_blackboard({"pos", Vec2{to_fixed(3), to_fixed(4)}}), // Id 0, distance 5
		index_blackboard({"pos", Vec2{to_fixed(6), to_fixed(8)}}), // Id 1, distance 10
		index_blackboard({"pos", Vec2{to_fixed(0), to_fixed(5)}}), // Id 2, distance 5
		index_blackboard({"pos", Vec2{to_fixed(20), to_fixed(0)}}), // Id 3, outside
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
	// AC (3D spatial): a Vec3 origin measures Vec3 keys through vec3_length —
	// (1,2,2) from the origin is exactly 3.0 — and the radius bound reads the
	// same kernel distance.
	version := index_test_version("Probe", {
		index_blackboard({"pos", Vec3{to_fixed(1), to_fixed(2), to_fixed(2)}}), // Id 0, distance 3
		index_blackboard({"pos", Vec3{to_fixed(9), to_fixed(0), to_fixed(0)}}), // Id 1, outside
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
	// AC (fail closed): an undeclared spatial requirement, a non-vector probe
	// origin, and a dimension-mismatched key each take the absent arm — the
	// kernel defines no distance there, and a refusal is never a coerced 0.
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
