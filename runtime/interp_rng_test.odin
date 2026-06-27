package funpack_runtime

import "core:fmt"
import "core:testing"

@(private = "file")
rng_node_fields :: proc(tokens: ..string) -> []string {
	out := make([]string, len(tokens), context.temp_allocator)
	copy(out, tokens)
	return out
}

@(private = "file")
rng_node_children :: proc(nodes: ..Node) -> []Node {
	out := make([]Node, len(nodes), context.temp_allocator)
	copy(out, nodes)
	return out
}

@(private = "file")
rng_interp :: proc() -> Interp {
	program := new(Program, context.temp_allocator)
	version := new(World_Version, context.temp_allocator)
	version^ = initial_version(World{}, context.temp_allocator)
	return new_interp(program, version, nil, empty(), Record_Value{}, context.temp_allocator)
}

@(private = "file")
rng_env :: proc() -> Env {
	return Env{names = make(map[string]Value, context.temp_allocator)}
}

@(test)
test_eval_tuple_builds_positional_aggregate :: proc(t: ^testing.T) {
	interp := rng_interp()
	env := rng_env()

	a := Node{kind = .Int, fields = rng_node_fields("1")}
	b := Node{kind = .Int, fields = rng_node_fields("2")}
	c := Node{kind = .Int, fields = rng_node_fields("3")}
	tuple_node := Node{kind = .Tuple, children = rng_node_children(a, b, c)}

	result, ok := eval(&interp, &tuple_node, &env)
	testing.expect(t, ok)
	tuple, is_tuple := result.(Tuple_Value)
	testing.expect(t, is_tuple)
	testing.expect_value(t, len(tuple.elements), 3)
	testing.expect_value(t, tuple.elements[0].(i64), i64(1))
	testing.expect_value(t, tuple.elements[1].(i64), i64(2))
	testing.expect_value(t, tuple.elements[2].(i64), i64(3))
}

@(test)
test_tuple_structural_equality :: proc(t: ^testing.T) {
	a := Tuple_Value{elements = []Value{i64(1), i64(2)}}
	b := Tuple_Value{elements = []Value{i64(1), i64(2)}}
	c := Tuple_Value{elements = []Value{i64(1), i64(3)}}
	d := Tuple_Value{elements = []Value{i64(1)}}
	testing.expect(t, values_equal(a, b))
	testing.expect(t, !values_equal(a, c))
	testing.expect(t, !values_equal(a, d))
}

@(test)
test_tuple_pattern_binds_nested_variant_and_bare_binder :: proc(t: ^testing.T) {
	some_sub := Node {
		kind   = .Arm,
		fields = rng_node_fields("variant_binds", "Option", "Some", "1", "cell"),
	}
	next_sub := Node {
		kind   = .Arm,
		fields = rng_node_fields("bare_binder", "-", "-", "1", "next"),
	}
	tuple_arm := Node {
		kind     = .Arm,
		fields   = rng_node_fields("tuple", "-", "-", "0"),
		children = rng_node_children(some_sub, next_sub),
	}

	payload := new(Value, context.temp_allocator)
	payload^ = i64(99)
	some := Variant_Value{enum_type = "Option", case_name = "Some", payload = payload}
	rng := Rng{state = 7}
	scrutinee := Tuple_Value{elements = []Value{some, rng}}

	scope := rng_env()
	matched := arm_matches(scrutinee, &tuple_arm, &scope)
	testing.expect(t, matched)
	cell, cell_present := scope.names["cell"]
	next, next_present := scope.names["next"]
	testing.expect(t, cell_present && next_present)
	testing.expect_value(t, cell.(i64), i64(99))
	testing.expect_value(t, next.(Rng).state, u64(7))
}

@(test)
test_tuple_pattern_none_scrutinee_misses_some_arm :: proc(t: ^testing.T) {
	some_sub := Node {
		kind   = .Arm,
		fields = rng_node_fields("variant_binds", "Option", "Some", "1", "cell"),
	}
	next_sub := Node {
		kind   = .Arm,
		fields = rng_node_fields("bare_binder", "-", "-", "1", "next"),
	}
	some_arm := Node {
		kind     = .Arm,
		fields   = rng_node_fields("tuple", "-", "-", "0"),
		children = rng_node_children(some_sub, next_sub),
	}

	none := Variant_Value{enum_type = "Option", case_name = "None"}
	scrutinee := Tuple_Value{elements = []Value{none, Rng{state = 3}}}

	scope := rng_env()
	testing.expect(t, !arm_matches(scrutinee, &some_arm, &scope))
}

@(test)
test_tuple_pattern_rejects_non_tuple_and_arity_mismatch :: proc(t: ^testing.T) {
	one_pos := Node{kind = .Arm, fields = rng_node_fields("bare_binder", "-", "-", "1", "x")}
	arm := Node {
		kind     = .Arm,
		fields   = rng_node_fields("tuple", "-", "-", "0"),
		children = rng_node_children(one_pos),
	}
	scope := rng_env()
	testing.expect(t, !arm_matches(i64(5), &arm, &scope))
	two := Tuple_Value{elements = []Value{i64(1), i64(2)}}
	testing.expect(t, !arm_matches(two, &arm, &scope))
}

@(test)
test_pick_some_boxes_element_and_advances :: proc(t: ^testing.T) {
	interp := rng_interp()
	env := rng_env()

	list := make([]Value, 10, context.temp_allocator)
	for i in 0 ..< 10 {
		list[i] = i64(100 * (i + 1))
	}
	env.names["free"] = List_Value{elements = list}
	env.names["rng"] = rand_seed(42)

	pick_node := pick_call_node()
	result, ok := eval(&interp, &pick_node, &env)
	testing.expect(t, ok)

	tuple, is_tuple := result.(Tuple_Value)
	testing.expect(t, is_tuple)
	testing.expect_value(t, len(tuple.elements), 2)

	option, is_variant := tuple.elements[0].(Variant_Value)
	testing.expect(t, is_variant)
	testing.expect_value(t, option.case_name, "Some")
	testing.expect(t, option.payload != nil)
	testing.expect_value(t, option.payload^.(i64), i64(100 * (RAND_SEED_42_BOUNDED_10[0] + 1)))

	advanced, is_rng := tuple.elements[1].(Rng)
	testing.expect(t, is_rng)
	_, want := rand_bounded(rand_seed(42), 10)
	testing.expect_value(t, advanced.state, want.state)
}

@(test)
test_pick_empty_is_none_but_advances :: proc(t: ^testing.T) {
	interp := rng_interp()
	env := rng_env()
	env.names["free"] = List_Value{elements = make([]Value, 0, context.temp_allocator)}
	env.names["rng"] = rand_seed(42)

	pick_node := pick_call_node()
	result, ok := eval(&interp, &pick_node, &env)
	testing.expect(t, ok)
	tuple := result.(Tuple_Value)

	option := tuple.elements[0].(Variant_Value)
	testing.expect_value(t, option.case_name, "None")
	testing.expect(t, option.payload == nil)

	advanced := tuple.elements[1].(Rng)
	_, want := rand_next(rand_seed(42))
	testing.expect_value(t, advanced.state, want.state)
}

@(test)
test_pick_threads_forward_deterministically :: proc(t: ^testing.T) {
	interp := rng_interp()

	list := make([]Value, 10, context.temp_allocator)
	for i in 0 ..< 10 {
		list[i] = i64(i)
	}

	pick_once :: proc(interp: ^Interp, list: []Value, rng: Rng) -> (idx: i64, next: Rng) {
		env := Env{names = make(map[string]Value, context.temp_allocator)}
		env.names["free"] = List_Value{elements = list}
		env.names["rng"] = rng
		node := pick_call_node()
		result, _ := eval(interp, &node, &env)
		tuple := result.(Tuple_Value)
		picked := tuple.elements[0].(Variant_Value).payload^.(i64)
		return picked, tuple.elements[1].(Rng)
	}

	idx0, next0 := pick_once(&interp, list, rand_seed(42))
	testing.expect_value(t, idx0, i64(RAND_SEED_42_BOUNDED_10[0]))
	idx1, _ := pick_once(&interp, list, next0)
	testing.expect_value(t, idx1, i64(RAND_SEED_42_BOUNDED_10[1]))

	r0, rn := pick_once(&interp, list, rand_seed(42))
	r1, _ := pick_once(&interp, list, rn)
	testing.expect_value(t, r0, idx0)
	testing.expect_value(t, r1, idx1)
}

@(private = "file")
pick_call_node :: proc() -> Node {
	callee := Node{kind = .Name, fields = rng_node_fields("pick")}
	rng_arg := Node{kind = .Name, fields = rng_node_fields("rng")}
	free_arg := Node{kind = .Name, fields = rng_node_fields("free")}
	return Node{kind = .Call, children = rng_node_children(callee, rng_arg, free_arg)}
}

@(private = "file")
rng_method_call_node :: proc(method: string, args: ..Node) -> Node {
	recv := Node{kind = .Name, fields = rng_node_fields("rng")}
	field := Node{kind = .Field, fields = rng_node_fields(method), children = rng_node_children(recv)}
	children := make([]Node, len(args) + 1, context.temp_allocator)
	children[0] = field
	copy(children[1:], args)
	return Node{kind = .Call, children = children}
}

@(test)
test_interp_seed_builds_kernel_rng :: proc(t: ^testing.T) {
	interp := rng_interp()
	env := rng_env()
	callee := Node{kind = .Name, fields = rng_node_fields("seed")}
	arg := Node{kind = .Int, fields = rng_node_fields("42")}
	call := Node{kind = .Call, children = rng_node_children(callee, arg)}
	result, ok := eval(&interp, &call, &env)
	testing.expect(t, ok)
	rng, is_rng := result.(Rng)
	testing.expect(t, is_rng)
	testing.expect_value(t, rng.state, rand_seed(42).state)
}

@(test)
test_interp_next_yields_golden_fixed_pair :: proc(t: ^testing.T) {
	interp := rng_interp()
	env := rng_env()
	env.names["rng"] = rand_seed(42)
	call := rng_method_call_node("next")
	result, ok := eval(&interp, &call, &env)
	testing.expect(t, ok)
	tuple := result.(Tuple_Value)
	testing.expect_value(t, len(tuple.elements), 2)
	testing.expect_value(t, i64(tuple.elements[0].(Fixed)), i64(803958421))
	want_fixed, want_next := rand_next_fixed(rand_seed(42))
	testing.expect_value(t, i64(tuple.elements[0].(Fixed)), i64(want_fixed))
	testing.expect_value(t, tuple.elements[1].(Rng).state, want_next.state)
}

@(test)
test_interp_range_yields_golden_int_pair :: proc(t: ^testing.T) {
	interp := rng_interp()
	env := rng_env()
	env.names["rng"] = rand_seed(42)
	lo := Node{kind = .Int, fields = rng_node_fields("0")}
	hi := Node{kind = .Int, fields = rng_node_fields("100")}
	call := rng_method_call_node("range", lo, hi)
	result, ok := eval(&interp, &call, &env)
	testing.expect(t, ok)
	tuple := result.(Tuple_Value)
	testing.expect_value(t, tuple.elements[0].(i64), i64(74))
	_, want_next := rand_range(rand_seed(42), 0, 100)
	testing.expect_value(t, tuple.elements[1].(Rng).state, want_next.state)
}

@(test)
test_interp_chance_endpoints :: proc(t: ^testing.T) {
	interp := rng_interp()
	env := rng_env()
	env.names["rng"] = rand_seed(42)
	zero := Node{kind = .Fixed, fields = rng_node_fields("0")}
	never_call := rng_method_call_node("chance", zero)
	never_res, never_ok := eval(&interp, &never_call, &env)
	testing.expect(t, never_ok)
	testing.expect(t, !never_res.(Tuple_Value).elements[0].(bool))

	one := Node{kind = .Fixed, fields = rng_node_fields(fixed_one_token())}
	always_call := rng_method_call_node("chance", one)
	always_res, always_ok := eval(&interp, &always_call, &env)
	testing.expect(t, always_ok)
	testing.expect(t, always_res.(Tuple_Value).elements[0].(bool))
}

@(test)
test_interp_split_yields_golden_stream_pair :: proc(t: ^testing.T) {
	interp := rng_interp()
	env := rng_env()
	env.names["rng"] = rand_seed(42)
	call := rng_method_call_node("split")
	result, ok := eval(&interp, &call, &env)
	testing.expect(t, ok)
	tuple := result.(Tuple_Value)
	want_a, want_b := rand_split(rand_seed(42))
	testing.expect_value(t, tuple.elements[0].(Rng).state, want_a.state)
	testing.expect_value(t, tuple.elements[1].(Rng).state, want_b.state)
	testing.expect(t, want_a.state != want_b.state)
}

@(private = "file")
fixed_one_token :: proc() -> string {
	return fmt.tprintf("%d", i64(FIXED_ONE))
}
