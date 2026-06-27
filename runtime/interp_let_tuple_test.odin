package funpack_runtime

import "core:strings"
import "core:testing"

@(private = "file")
LET_TUPLE_RANGE_BODY :: "node let_tuple 2 v r1 1\n" +
	"node call 3\n" +
	"node field range 1\n" +
	"node name rng 0\n" +
	"node int 0 0\n" +
	"node int 10 0\n" +
	"node return 1\n" +
	"node name v 0\n"

@(private = "file")
let_tuple_interp :: proc() -> Interp {
	program := new(Program, context.temp_allocator)
	version := new(World_Version, context.temp_allocator)
	version^ = initial_version(World{}, context.temp_allocator)
	return new_interp(program, version, nil, empty(), Record_Value{}, context.temp_allocator)
}

@(private = "file")
let_tuple_body_forest :: proc(text: string, body_count: int) -> []Node {
	lines := strings.split_lines(strings.trim_space(text), context.temp_allocator)
	statements, err := parse_node_forest(lines, body_count, context.temp_allocator)
	return statements if err == .None else nil
}

@(test)
test_let_tuple_decodes_count_driven :: proc(t: ^testing.T) {
	line := "node let_tuple 2 v r1 1"

	count, count_ok := node_child_count(line)
	testing.expect(t, count_ok)
	testing.expect_value(t, count, 1)

	scalars := node_scalar_fields(line, context.temp_allocator)
	testing.expect_value(t, len(scalars), 3)
	testing.expect_value(t, scalars[0], "2")
	testing.expect_value(t, scalars[1], "v")
	testing.expect_value(t, scalars[2], "r1")

	kind, kind_ok := node_kind_from_tag("let_tuple")
	testing.expect(t, kind_ok)
	testing.expect_value(t, kind, Node_Kind.Let_Tuple)
}

@(test)
test_let_tuple_forest_parse :: proc(t: ^testing.T) {
	body := let_tuple_body_forest(LET_TUPLE_RANGE_BODY, 2)
	testing.expect_value(t, len(body), 2)

	let_tuple := body[0]
	testing.expect_value(t, let_tuple.kind, Node_Kind.Let_Tuple)
	testing.expect_value(t, len(let_tuple.fields), 3)
	testing.expect_value(t, let_tuple.fields[1], "v")
	testing.expect_value(t, let_tuple.fields[2], "r1")
	testing.expect_value(t, len(let_tuple.children), 1)
	testing.expect_value(t, let_tuple.children[0].kind, Node_Kind.Call)
}

@(test)
test_let_tuple_binds_positionally_seed_42 :: proc(t: ^testing.T) {
	interp := let_tuple_interp()
	env := Env {
		names = make(map[string]Value, context.temp_allocator),
	}
	env.names["rng"] = rand_seed(42)

	body := let_tuple_body_forest(LET_TUPLE_RANGE_BODY, 2)
	testing.expect_value(t, len(body), 2)

	returned, ok := eval_body(&interp, body, &env)
	testing.expect(t, ok)
	testing.expect_value(t, returned.(i64), i64(7))

	v_bound, v_present := env.names["v"]
	r1_bound, r1_present := env.names["r1"]
	testing.expect(t, v_present && r1_present)

	want_v, want_next := rand_range(rand_seed(42), 0, 10)
	testing.expect_value(t, v_bound.(i64), want_v)
	testing.expect_value(t, v_bound.(i64), i64(7))
	testing.expect_value(t, r1_bound.(Rng).state, want_next.state)
}

@(test)
test_bind_let_tuple_value_arity_and_fail_closed :: proc(t: ^testing.T) {
	{
		env := Env{names = make(map[string]Value, context.temp_allocator)}
		tuple := Tuple_Value {
			elements = []Value{i64(7), rand_seed(42)},
		}
		ok := bind_let_tuple_value(&env, []string{"v", "r1"}, tuple)
		testing.expect(t, ok)
		testing.expect_value(t, env.names["v"].(i64), i64(7))
		testing.expect_value(t, env.names["r1"].(Rng).state, rand_seed(42).state)
	}

	{
		env := Env{names = make(map[string]Value, context.temp_allocator)}
		tuple := Tuple_Value {
			elements = []Value{i64(1), i64(2)},
		}
		ok := bind_let_tuple_value(&env, []string{"a", "b", "c"}, tuple)
		testing.expect(t, !ok)
		_, a_present := env.names["a"]
		testing.expect(t, !a_present)
	}

	{
		env := Env{names = make(map[string]Value, context.temp_allocator)}
		ok := bind_let_tuple_value(&env, []string{"a", "b"}, i64(99))
		testing.expect(t, !ok)
		_, a_present := env.names["a"]
		testing.expect(t, !a_present)
	}
}

@(test)
test_let_tuple_binds_inside_guard_block :: proc(t: ^testing.T) {
	guard_body :: "node if_return 2\n" +
		"node name true_lit 0\n" +
		"node block 2\n" +
		"node let_tuple 2 v r1 1\n" +
		"node call 3\n" +
		"node field range 1\n" +
		"node name rng 0\n" +
		"node int 0 0\n" +
		"node int 10 0\n" +
		"node return 1\n" +
		"node name v 0\n" +
		"node return 1\n" +
		"node int 0 0\n"

	interp := let_tuple_interp()
	env := Env {
		names = make(map[string]Value, context.temp_allocator),
	}
	env.names["rng"] = rand_seed(42)
	env.names["true_lit"] = true

	body := let_tuple_body_forest(guard_body, 2)
	testing.expect_value(t, len(body), 2)

	returned, ok := eval_body(&interp, body, &env)
	testing.expect(t, ok)
	testing.expect_value(t, returned.(i64), i64(7))

	_, v_leaked := env.names["v"]
	testing.expect(t, !v_leaked)
}
