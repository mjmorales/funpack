package funpack_runtime

import "core:testing"

@(private = "file")
make_interp :: proc(program: ^Program, version: ^World_Version) -> Interp {
	dt_fields := make(map[string]Value, context.temp_allocator)
	dt_fields["dt"] = dt_60hz()
	time := Record_Value{type_name = "Time", fields = dt_fields}
	return new_interp(program, version, nil, empty(), time, context.temp_allocator)
}

@(private = "file")
dt_60hz :: proc() -> Fixed {
	return fixed_div(to_fixed(1), to_fixed(60))
}

@(test)
test_eval_const_board :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)
	interp := make_interp(&program, &version)

	board, board_ok := eval_const(&interp, "BOARD")
	testing.expect(t, board_ok)
	record, is_record := board.(Record_Value)
	testing.expect(t, is_record)
	w, w_present := record.fields["w"]
	h, h_present := record.fields["h"]
	testing.expect(t, w_present && h_present)
	testing.expect_value(t, w.(Fixed), to_fixed(160))
	testing.expect_value(t, h.(Fixed), to_fixed(120))
}

@(test)
test_eval_user_call_advance :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)
	interp := make_interp(&program, &version)

	at := Vec2{to_fixed(80), to_fixed(60)}
	vel := Vec2{to_fixed(70), to_fixed(40)}
	dt := dt_60hz()
	result, result_ok := call_three(&interp, "advance", at, vel, dt)
	testing.expect(t, result_ok)

	got := result.(Vec2)
	want := Vec2{fixed_add(at.x, fixed_mul(vel.x, dt)), fixed_add(at.y, fixed_mul(vel.y, dt))}
	testing.expect_value(t, got.x, want.x)
	testing.expect_value(t, got.y, want.y)
}

@(test)
test_eval_goal_side_all_arms :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)
	interp := make_interp(&program, &version)

	left_edge := goal_side_case(&interp, Vec2{fixed_neg(to_fixed(5)), to_fixed(60)})
	testing.expect_value(t, left_edge.case_name, "Some")
	testing.expect_value(t, left_edge.payload.(Variant_Value).case_name, "Right")

	right_edge := goal_side_case(&interp, Vec2{to_fixed(200), to_fixed(60)})
	testing.expect_value(t, right_edge.case_name, "Some")
	testing.expect_value(t, right_edge.payload.(Variant_Value).case_name, "Left")

	in_bounds := goal_side_case(&interp, Vec2{to_fixed(80), to_fixed(60)})
	testing.expect_value(t, in_bounds.case_name, "None")
}

@(test)
test_eval_add_goal_increments_side :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)
	interp := make_interp(&program, &version)

	score := record_value(&interp, "Scoreboard", {"left", i64(2)}, {"right", i64(5)})
	left_goal := goal_value(&interp, "Left")
	updated, updated_ok := call_two(&interp, "add_goal", score, left_goal)
	testing.expect(t, updated_ok)

	out := updated.(Record_Value)
	testing.expect_value(t, out.fields["left"].(i64), i64(3))
	testing.expect_value(t, out.fields["right"].(i64), i64(5))
}

@(test)
test_eval_serve_velocity :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)
	interp := make_interp(&program, &version)

	left_vel := serve_velocity_for(&interp, "Left")
	testing.expect_value(t, left_vel.x, to_fixed(70))
	testing.expect_value(t, left_vel.y, to_fixed(40))

	right_vel := serve_velocity_for(&interp, "Right")
	testing.expect_value(t, right_vel.x, fixed_neg(to_fixed(70)))
	testing.expect_value(t, right_vel.y, to_fixed(40))
}

@(test)
test_eval_input_axis_reads_snapshot :: proc(t: ^testing.T) {
	program := axis_program()
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)

	move := Vec2{fixed_div(to_fixed(1), to_fixed(2)), fixed_neg(fixed_div(to_fixed(1), to_fixed(4)))}
	snap := with_axis(empty(), .P1, ActionId(0), move)
	defer delete_input(snap)

	dt_fields := make(map[string]Value, context.temp_allocator)
	dt_fields["dt"] = dt_60hz()
	time := Record_Value{type_name = "Time", fields = dt_fields}
	interp := new_interp(&program, &version, nil, snap, time, context.temp_allocator)

	_, has_move := registry_find_token(interp.registry, "Drive::Move")
	testing.expect(t, has_move)

	got, ok := eval_axis_call(&interp, "P1", "Drive", "Move")
	testing.expect(t, ok)
	vec := got.(Vec2)
	testing.expect_value(t, vec.x, move.x)
	testing.expect_value(t, vec.y, move.y)
}

@(test)
test_eval_input_axis_unwritten_reads_zero :: proc(t: ^testing.T) {
	program := axis_program()
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)

	snap := with_axis(empty(), .P1, ActionId(0), Vec2{to_fixed(1), to_fixed(1)})
	defer delete_input(snap)

	dt_fields := make(map[string]Value, context.temp_allocator)
	dt_fields["dt"] = dt_60hz()
	time := Record_Value{type_name = "Time", fields = dt_fields}
	interp := new_interp(&program, &version, nil, snap, time, context.temp_allocator)

	got, ok := eval_axis_call(&interp, "P2", "Drive", "Move")
	testing.expect(t, ok)
	vec := got.(Vec2)
	testing.expect_value(t, vec.x, VEC2_ZERO.x)
	testing.expect_value(t, vec.y, VEC2_ZERO.y)
}

@(test)
test_eval_length_perfect_square :: proc(t: ^testing.T) {
	program := Program{}
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)
	interp := make_interp(&program, &version)

	got, ok := eval_length_call(&interp, Vec2{to_fixed(3), to_fixed(4)})
	testing.expect(t, ok)
	testing.expect_value(t, got.(Fixed), to_fixed(5))
}

@(test)
test_eval_length_floor_case :: proc(t: ^testing.T) {
	program := Program{}
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)
	interp := make_interp(&program, &version)

	v := Vec2{to_fixed(1), to_fixed(1)}
	got, ok := eval_length_call(&interp, v)
	testing.expect(t, ok)
	testing.expect_value(t, got.(Fixed), fixed_sqrt(vec2_dot(v, v)))
}

@(test)
test_eval_length_non_vec2_fails :: proc(t: ^testing.T) {
	program := Program{}
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)
	interp := make_interp(&program, &version)

	_, ok := eval_length_call(&interp, to_fixed(7))
	testing.expect(t, !ok)
}

@(private = "file")
axis_program :: proc() -> Program {
	enums := make([]Enum_Decl, 1, context.temp_allocator)
	variants := make([]Enum_Variant, 1, context.temp_allocator)
	variants[0] = Enum_Variant{name = "Move", payload = "unit"}
	enums[0] = Enum_Decl{name = "Drive", kind = .Axis, variants = variants}
	return Program{enums = enums}
}

@(private = "file")
eval_axis_call :: proc(
	interp: ^Interp,
	player, action_enum, action_case: string,
) -> (
	result: Value,
	ok: bool,
) {
	recv := Node{kind = .Name, fields = node_fields("input")}
	field := Node{kind = .Field, fields = node_fields("axis"), children = node_children(recv)}
	player_arg := variant_node("PlayerId", player)
	action_arg := variant_node(action_enum, action_case)
	call := Node {
		kind     = .Call,
		children = node_children(field, player_arg, action_arg),
	}

	env := Env {
		names = make(map[string]Value, context.temp_allocator),
	}
	env.names["input"] = input_marker(interp)
	return eval(interp, &call, &env)
}

@(private = "file")
eval_length_call :: proc(interp: ^Interp, arg: Value) -> (result: Value, ok: bool) {
	callee := Node{kind = .Name, fields = node_fields("length")}
	arg_node := Node{kind = .Name, fields = node_fields("v")}
	call := Node {
		kind     = .Call,
		children = node_children(callee, arg_node),
	}

	env := Env {
		names = make(map[string]Value, context.temp_allocator),
	}
	env.names["v"] = arg
	return eval(interp, &call, &env)
}

@(private = "file")
variant_node :: proc(enum_type, case_name: string) -> Node {
	return Node{kind = .Variant, fields = node_fields(enum_type, case_name, "false")}
}

@(private = "file")
node_fields :: proc(tokens: ..string) -> []string {
	out := make([]string, len(tokens), context.temp_allocator)
	copy(out, tokens)
	return out
}

@(private = "file")
node_children :: proc(nodes: ..Node) -> []Node {
	out := make([]Node, len(nodes), context.temp_allocator)
	copy(out, nodes)
	return out
}

@(private = "file")
call_three :: proc(
	interp: ^Interp,
	name: string,
	a, b, c: Value,
) -> (
	result: Value,
	ok: bool,
) {
	fn := program_function(interp.program, name)
	if fn == nil || len(fn.params) != 3 {
		return nil, false
	}
	scope := Env{names = make(map[string]Value, interp.allocator)}
	scope.names[fn.params[0].name] = a
	scope.names[fn.params[1].name] = b
	scope.names[fn.params[2].name] = c
	return eval_body(interp, fn.body, &scope)
}

@(private = "file")
call_two :: proc(interp: ^Interp, name: string, a, b: Value) -> (result: Value, ok: bool) {
	fn := program_function(interp.program, name)
	if fn == nil || len(fn.params) != 2 {
		return nil, false
	}
	return apply_two_arg(interp, fn, a, b)
}

@(private = "file")
call_one :: proc(interp: ^Interp, name: string, a: Value) -> (result: Value, ok: bool) {
	fn := program_function(interp.program, name)
	if fn == nil || len(fn.params) != 1 {
		return nil, false
	}
	scope := Env{names = make(map[string]Value, interp.allocator)}
	scope.names[fn.params[0].name] = a
	return eval_body(interp, fn.body, &scope)
}

@(private = "file")
goal_side_case :: proc(interp: ^Interp, at: Vec2) -> Variant_Value {
	result, ok := call_one(interp, "goal_side", at)
	if !ok {
		return Variant_Value{}
	}
	return result.(Variant_Value)
}

@(private = "file")
serve_velocity_for :: proc(interp: ^Interp, side: string) -> Vec2 {
	result, ok := call_one(interp, "serve_velocity", side_value(interp, side))
	if !ok {
		return VEC2_ZERO
	}
	return result.(Vec2)
}

@(private = "file")
record_value :: proc(
	interp: ^Interp,
	type_name: string,
	pairs: ..struct {
		name:  string,
		value: Value,
	},
) -> Value {
	fields := make(map[string]Value, interp.allocator)
	for pair in pairs {
		fields[pair.name] = pair.value
	}
	return Record_Value{type_name = type_name, fields = fields}
}

@(private = "file")
side_value :: proc(interp: ^Interp, case_name: string) -> Value {
	return Variant_Value{enum_type = "Side", case_name = case_name}
}

@(private = "file")
goal_value :: proc(interp: ^Interp, side: string) -> Value {
	fields := make(map[string]Value, interp.allocator)
	fields["side"] = side_value(interp, side)
	return Record_Value{type_name = "Goal", fields = fields}
}
