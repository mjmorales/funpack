// The §08 §3 query-evaluation contract: a call to a declared query dispatches
// through the named-call surface and folds its carried body as a pure read
// (exact-equality pins per form), the result memoizes WITHIN one tick on the
// canonical (name, argument-bytes) key — same args hit, different args miss,
// framed per argument so lists can never alias across a boundary, cleared at
// the tick boundary by construction — and the @spatial radius query answers
// nearest-first with fixed-point bounds and the stable-Id tiebreak, failing
// closed wherever the kernel defines no distance. Hand-built node forests and
// committed versions per test — the interp_test / index_test molds.
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

// doubled_query builds the §08 §3 memoizable value-parameter form by hand:
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
// in flight, so the within-tick memo is live. The version is the empty world —
// these fixtures read no tables.
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

@(test)
test_query_memoizes_within_tick :: proc(t: ^testing.T) {
	// AC (§08 §3 within-tick memoization): the first call with a key computes
	// (one miss), a same-args re-call within the tick returns the cached value
	// (one hit, no second fold), and different args compute their own entry.
	queries := make([]Query_Decl, 1, context.temp_allocator)
	queries[0] = doubled_query()
	program := Program {
		queries = queries,
	}
	version := World_Version{tick = 0}
	tick := new_tick_state(version, context.temp_allocator, context.temp_allocator)
	interp := query_test_interp(&program, &version, &tick)
	query := &program.queries[0]

	args := make([]Value, 1, context.temp_allocator)
	args[0] = to_fixed(3)
	first, first_ok := eval_query_values(&interp, query, args)
	testing.expect_value(t, first_ok, true)
	testing.expect_value(t, tick.query_memo_misses, 1)
	testing.expect_value(t, tick.query_memo_hits, 0)

	second, second_ok := eval_query_values(&interp, query, args)
	testing.expect_value(t, second_ok, true)
	testing.expect_value(t, tick.query_memo_hits, 1)
	testing.expect_value(t, values_equal(first, second), true)

	other := make([]Value, 1, context.temp_allocator)
	other[0] = to_fixed(5)
	third, third_ok := eval_query_values(&interp, query, other)
	testing.expect_value(t, third_ok, true)
	testing.expect_value(t, tick.query_memo_misses, 2)
	got, _ := third.(Fixed)
	testing.expect_value(t, got, to_fixed(10))

	// The cache lives ON the tick state, so a fresh tick starts empty — the
	// boundary clears the memo by construction.
	next_tick := new_tick_state(version, context.temp_allocator, context.temp_allocator)
	testing.expect_value(t, len(next_tick.query_memo), 0)
}

@(test)
test_query_memo_key_frames_each_argument :: proc(t: ^testing.T) {
	// AC (sound keys): every argument's canonical bytes are length-prefixed, so
	// two argument lists whose concatenated content matches still key apart —
	// ("ab", "c") never hits ("a", "bc")'s entry.
	echo_body := make([]Node, 1, context.temp_allocator)
	echo_body[0] = Node {
		kind     = .Return,
		children = query_node_children(Node{kind = .Name, fields = query_node_fields("a")}),
	}
	params := make([]Param_Decl, 2, context.temp_allocator)
	params[0] = Param_Decl{name = "a", type = "String"}
	params[1] = Param_Decl{name = "b", type = "String"}
	queries := make([]Query_Decl, 1, context.temp_allocator)
	queries[0] = Query_Decl{name = "echo", params = params, return_type = "String", body = echo_body}
	program := Program {
		queries = queries,
	}
	version := World_Version{tick = 0}
	tick := new_tick_state(version, context.temp_allocator, context.temp_allocator)
	interp := query_test_interp(&program, &version, &tick)
	query := &program.queries[0]

	joined_left := make([]Value, 2, context.temp_allocator)
	joined_left[0] = String_Value{text = "ab"}
	joined_left[1] = String_Value{text = "c"}
	_, left_ok := eval_query_values(&interp, query, joined_left)
	testing.expect_value(t, left_ok, true)

	joined_right := make([]Value, 2, context.temp_allocator)
	joined_right[0] = String_Value{text = "a"}
	joined_right[1] = String_Value{text = "bc"}
	_, right_ok := eval_query_values(&interp, query, joined_right)
	testing.expect_value(t, right_ok, true)

	testing.expect_value(t, tick.query_memo_misses, 2)
	testing.expect_value(t, tick.query_memo_hits, 0)
}

@(test)
test_query_view_shaped_argument_memoizes_by_content :: proc(t: ^testing.T) {
	// AC (the interim View-parameter read memoizes soundly): a query reading
	// the world through a row-list argument keys on the FULL list content —
	// the same rows hit, a changed column misses, so a memo answer can never
	// survive a write it should observe.
	count_body := make([]Node, 1, context.temp_allocator)
	count_call := Node {
		kind     = .Call,
		children = query_node_children(
			Node{kind = .Name, fields = query_node_fields("len")},
			Node{kind = .Name, fields = query_node_fields("items")},
		),
	}
	count_body[0] = Node{kind = .Return, children = query_node_children(count_call)}
	params := make([]Param_Decl, 1, context.temp_allocator)
	params[0] = Param_Decl{name = "items", type = "View[Ball]"}
	queries := make([]Query_Decl, 1, context.temp_allocator)
	queries[0] = Query_Decl{name = "ball_count", params = params, return_type = "Int", body = count_body}
	program := Program {
		queries = queries,
	}
	version := World_Version{tick = 0}
	tick := new_tick_state(version, context.temp_allocator, context.temp_allocator)
	interp := query_test_interp(&program, &version, &tick)
	query := &program.queries[0]

	row := make(map[string]Value, context.temp_allocator)
	row["pos"] = Vec2{to_fixed(1), to_fixed(2)}
	elements := make([]Value, 1, context.temp_allocator)
	elements[0] = Record_Value{type_name = "Ball", fields = row}
	args := make([]Value, 1, context.temp_allocator)
	args[0] = List_Value{elements = elements}

	first, first_ok := eval_query_values(&interp, query, args)
	testing.expect_value(t, first_ok, true)
	count, _ := first.(i64)
	testing.expect_value(t, count, i64(1))
	_, again_ok := eval_query_values(&interp, query, args)
	testing.expect_value(t, again_ok, true)
	testing.expect_value(t, tick.query_memo_hits, 1)

	// A same-tick caller observing a DIFFERENT column value misses — the key
	// is the content, not the parameter name.
	row["pos"] = Vec2{to_fixed(9), to_fixed(2)}
	_, moved_ok := eval_query_values(&interp, query, args)
	testing.expect_value(t, moved_ok, true)
	testing.expect_value(t, tick.query_memo_misses, 2)
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
