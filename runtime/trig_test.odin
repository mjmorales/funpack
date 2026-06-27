package funpack_runtime

import "core:testing"

PINNED_ANGLE_BITS :: [8]i64 {
	0,
	3373259426,
	6746518852,
	10119778278,
	13493037704,
	20239556556,
	26986075409,
	3006477107,
}

PINNED_SIN_BITS :: [8]i64 {
	0,
	3037156255,
	4314401403,
	3355363922,
	2250751470,
	28504265673,
	199916693143,
	2766963603,
}

@(private = "file")
pinned_angles :: proc() -> [8]Fixed {
	tau := TAU_FIXED
	eighth := fixed_div(tau, to_fixed(8))
	quarter := fixed_div(tau, to_fixed(4))
	half := fixed_div(tau, to_fixed(2))
	return [8]Fixed {
		Fixed(0),
		eighth,
		quarter,
		fixed_mul(to_fixed(3), eighth),
		half,
		fixed_mul(to_fixed(3), quarter),
		tau,
		fixed_div(to_fixed(7), to_fixed(10)),
	}
}

@(test)
test_fixed_sin_cardinals :: proc(t: ^testing.T) {
	testing.expect_value(t, fixed_sin(Fixed(0)), Fixed(0))

	angles := pinned_angles()
	expected_angle := PINNED_ANGLE_BITS
	for a, i in angles {
		testing.expect_value(t, i64(a), expected_angle[i])
	}
	expected_sin := PINNED_SIN_BITS
	for a, i in angles {
		testing.expect_value(t, i64(fixed_sin(a)), expected_sin[i])
	}
}

@(test)
test_fixed_sin_matches_funpack_bits :: proc(t: ^testing.T) {
	angles := pinned_angles()
	expected := PINNED_SIN_BITS
	for a, i in angles {
		got := i64(fixed_sin(a))
		testing.expect_value(t, got, expected[i])
	}
}

@(test)
test_eval_sin_and_tau :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)
	interp := make_trig_interp(&program, &version)

	env := root_env()
	tau_val, tau_ok := eval_name(&interp, "tau", &env)
	testing.expect(t, tau_ok)
	testing.expect_value(t, tau_val.(Fixed), TAU_FIXED)

	angle := fixed_div(TAU_FIXED, to_fixed(4))
	sin_val, sin_ok := eval_sin_call(&interp, angle)
	testing.expect(t, sin_ok)
	testing.expect_value(t, sin_val.(Fixed), fixed_sin(angle))

	zero_val, zero_ok := eval_sin_call(&interp, Fixed(0))
	testing.expect(t, zero_ok)
	testing.expect_value(t, zero_val.(Fixed), Fixed(0))

	_, vec_ok := eval_sin_call(&interp, Vec2{to_fixed(1), to_fixed(2)})
	testing.expect(t, !vec_ok)
}

@(private = "file")
make_trig_interp :: proc(program: ^Program, version: ^World_Version) -> Interp {
	dt_fields := make(map[string]Value, context.temp_allocator)
	dt_fields["dt"] = fixed_div(to_fixed(1), to_fixed(60))
	time := Record_Value{type_name = "Time", fields = dt_fields}
	return new_interp(program, version, nil, empty(), time, context.temp_allocator)
}

@(private = "file")
root_env :: proc() -> Env {
	return Env{names = make(map[string]Value, context.temp_allocator)}
}

@(private = "file")
eval_sin_call :: proc(interp: ^Interp, arg: Value) -> (result: Value, ok: bool) {
	callee := Node{kind = .Name, fields = trig_node_fields("sin")}
	arg_node := Node{kind = .Name, fields = trig_node_fields("a")}
	call := Node {
		kind     = .Call,
		children = trig_node_children(callee, arg_node),
	}
	env := Env {
		names = make(map[string]Value, context.temp_allocator),
	}
	env.names["a"] = arg
	return eval(interp, &call, &env)
}

@(private = "file")
trig_node_fields :: proc(tokens: ..string) -> []string {
	out := make([]string, len(tokens), context.temp_allocator)
	copy(out, tokens)
	return out
}

@(private = "file")
trig_node_children :: proc(nodes: ..Node) -> []Node {
	out := make([]Node, len(nodes), context.temp_allocator)
	copy(out, nodes)
	return out
}
