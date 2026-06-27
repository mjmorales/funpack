package funpack_runtime

import "core:strconv"

hunt_program :: proc() -> Program {
	a := context.temp_allocator

	enums := make([]Enum_Decl, 2, a)
	enums[0] = Enum_Decl{name = "Hunt", kind = .None, variants = hunt_variants(a)}
	enums[1] = Enum_Decl{name = "Drive", kind = .Axis, variants = drive_variants(a)}

	things := make([]Thing_Decl, 2, a)
	things[0] = Thing_Decl{name = "Player", fields = player_fields(a)}
	things[1] = Thing_Decl{name = "Hunter", singleton = false, fields = hunter_fields(a)}

	functions := make([]Function_Decl, 9, a)
	functions[0] = const_fn("SIGHT", hf_fixed_node(to_fixed(30), a), a)
	functions[1] = const_fn("H_SPEED", hf_fixed_node(to_fixed(1), a), a)
	functions[2] = const_fn("SEARCH_TIME", hf_fixed_node(to_fixed(2), a), a)
	functions[3] = step_to_fn(a)
	functions[4] = visible_fn(a)
	functions[5] = patrol_fn(a)
	functions[6] = chase_fn(a)
	functions[7] = search_fn(a)
	functions[8] = seek_fn(a)

	behaviors := make([]Behavior_Decl, 1, a)
	behaviors[0] = think_behavior(a)

	pipeline := make([]Pipeline_Step, 1, a)
	pipeline[0] = Pipeline_Step{ordinal = 0, stage = "ai", behavior = "think"}

	setup := make([]Spawn_Command, 3, a)
	setup[0] = Spawn_Command{thing = "Player", fields = vec2_spawn(a, "pos", to_fixed(10), to_fixed(0))}
	setup[1] = Spawn_Command{thing = "Hunter", fields = hunter_spawn(a, to_fixed(5), to_fixed(0))}
	setup[2] = Spawn_Command{thing = "Hunter", fields = hunter_spawn(a, to_fixed(200), to_fixed(0))}

	return Program {
		enums = enums,
		things = things,
		functions = functions,
		behaviors = behaviors,
		pipeline = pipeline,
		setup = setup,
	}
}

@(private = "file")
hunt_variants :: proc(a := context.allocator) -> []Enum_Variant {
	v := make([]Enum_Variant, 3, a)
	v[0] = Enum_Variant{name = "Patrol", payload = "unit"}
	v[1] = Enum_Variant{name = "Chase", payload = "unit"}
	v[2] = Enum_Variant{name = "Search", payload = "unit"}
	return v
}

@(private = "file")
drive_variants :: proc(a := context.allocator) -> []Enum_Variant {
	v := make([]Enum_Variant, 1, a)
	v[0] = Enum_Variant{name = "Move", payload = "unit"}
	return v
}

@(private = "file")
player_fields :: proc(a := context.allocator) -> []Field_Decl {
	f := make([]Field_Decl, 1, a)
	f[0] = Field_Decl{name = "pos", type = "Vec2"}
	return f
}

@(private = "file")
hunter_fields :: proc(a := context.allocator) -> []Field_Decl {
	f := make([]Field_Decl, 5, a)
	f[0] = Field_Decl{name = "pos", type = "Vec2"}
	f[1] = Field_Decl{name = "home", type = "Vec2"}
	f[2] = Field_Decl{name = "ai", type = "Hunt", has_default = true, default_encoded = "Hunt::Patrol"}
	f[3] = Field_Decl{name = "last_seen", type = "Vec2"}
	f[4] = Field_Decl{name = "search_t", type = "Fixed", has_default = true, default_encoded = encode_fixed_bits(to_fixed(0), a)}
	return f
}

@(private = "file")
step_to_fn :: proc(a := context.allocator) -> Function_Decl {
	params := make([]Param_Decl, 3, a)
	params[0] = Param_Decl{name = "from", type = "Vec2"}
	params[1] = Param_Decl{name = "to", type = "Vec2"}
	params[2] = Param_Decl{name = "speed", type = "Fixed"}

	body := make([]Node, 4, a)
	body[0] = let_node("delta", binary_node("sub", name_node("to", a), name_node("from", a), a), a)
	body[1] = let_node("d", call_node_h(a, "length", name_node("delta", a)), a)
	body[2] = if_return_node(
		binary_node("le", name_node("d", a), name_node("speed", a), a),
		name_node("to", a),
		a,
	)
	scaled := binary_node(
		"mul",
		name_node("delta", a),
		binary_node("div", name_node("speed", a), name_node("d", a), a),
		a,
	)
	body[3] = return_node_h(binary_node("add", name_node("from", a), scaled, a), a)
	return Function_Decl{name = "step_to", kind = .Fn, params = params, body = body}
}

@(private = "file")
visible_fn :: proc(a := context.allocator) -> Function_Decl {
	params := make([]Param_Decl, 2, a)
	params[0] = Param_Decl{name = "from", type = "Vec2"}
	params[1] = Param_Decl{name = "players", type = "View[Player]"}

	pred_body := binary_node(
		"le",
		call_node_h(a, "length", binary_node("sub", field_node_h(name_node("p", a), "pos", a), name_node("from", a), a)),
		name_node("SIGHT", a),
		a,
	)
	pred := lambda_node_h(a, pred_body, "p")

	scrutinee := call_node_h(a, "first", name_node("players", a), pred)

	some_arm := variant_binds_arm("Option", "Some", "p", a)
	some_body := variant_payload_node("Option", "Some", field_node_h(name_node("p", a), "pos", a), a)
	none_arm := bare_variant_arm("Option", "None", a)
	none_body := variant_unit_node("Option", "None", a)

	match := match_node(scrutinee, a, some_arm, some_body, none_arm, none_body)
	body := make([]Node, 1, a)
	body[0] = return_node_h(match, a)
	return Function_Decl{name = "visible", kind = .Fn, params = params, body = body}
}

@(private = "file")
patrol_fn :: proc(a := context.allocator) -> Function_Decl {
	params := hunter_seen_params(a)

	some_arm := variant_binds_arm("Option", "Some", "p", a)
	some_body := with_node(
		name_node("self", a),
		a,
		recfield_spec("ai", variant_unit_node("Hunt", "Chase", a)),
		recfield_spec("last_seen", name_node("p", a)),
	)
	none_arm := bare_variant_arm("Option", "None", a)
	none_body := with_node(
		name_node("self", a),
		a,
		recfield_spec(
			"pos",
			call_node_h(
				a,
				"step_to",
				field_node_h(name_node("self", a), "pos", a),
				field_node_h(name_node("self", a), "home", a),
				name_node("H_SPEED", a),
			),
		),
	)

	match := match_node(name_node("seen", a), a, some_arm, some_body, none_arm, none_body)
	body := make([]Node, 1, a)
	body[0] = return_node_h(match, a)
	return Function_Decl{name = "patrol", kind = .Fn, params = params, body = body}
}

@(private = "file")
chase_fn :: proc(a := context.allocator) -> Function_Decl {
	params := hunter_seen_params(a)

	some_arm := variant_binds_arm("Option", "Some", "p", a)
	some_body := with_node(
		name_node("self", a),
		a,
		recfield_spec(
			"pos",
			call_node_h(
				a,
				"step_to",
				field_node_h(name_node("self", a), "pos", a),
				name_node("p", a),
				name_node("H_SPEED", a),
			),
		),
		recfield_spec("last_seen", name_node("p", a)),
	)
	none_arm := bare_variant_arm("Option", "None", a)
	none_body := with_node(
		name_node("self", a),
		a,
		recfield_spec("ai", variant_unit_node("Hunt", "Search", a)),
		recfield_spec("search_t", name_node("SEARCH_TIME", a)),
	)

	match := match_node(name_node("seen", a), a, some_arm, some_body, none_arm, none_body)
	body := make([]Node, 1, a)
	body[0] = return_node_h(match, a)
	return Function_Decl{name = "chase", kind = .Fn, params = params, body = body}
}

@(private = "file")
search_fn :: proc(a := context.allocator) -> Function_Decl {
	params := make([]Param_Decl, 3, a)
	params[0] = Param_Decl{name = "self", type = "Hunter"}
	params[1] = Param_Decl{name = "seen", type = "Option[Vec2]"}
	params[2] = Param_Decl{name = "dt", type = "Fixed"}

	some_arm := variant_binds_arm("Option", "Some", "p", a)
	some_body := with_node(
		name_node("self", a),
		a,
		recfield_spec("ai", variant_unit_node("Hunt", "Chase", a)),
		recfield_spec("last_seen", name_node("p", a)),
	)
	none_arm := bare_variant_arm("Option", "None", a)
	none_body := call_node_h(a, "seek", name_node("self", a), name_node("dt", a))

	match := match_node(name_node("seen", a), a, some_arm, some_body, none_arm, none_body)
	body := make([]Node, 1, a)
	body[0] = return_node_h(match, a)
	return Function_Decl{name = "search", kind = .Fn, params = params, body = body}
}

@(private = "file")
seek_fn :: proc(a := context.allocator) -> Function_Decl {
	params := make([]Param_Decl, 2, a)
	params[0] = Param_Decl{name = "self", type = "Hunter"}
	params[1] = Param_Decl{name = "dt", type = "Fixed"}

	body := make([]Node, 3, a)
	body[0] = let_node(
		"t",
		binary_node("sub", field_node_h(name_node("self", a), "search_t", a), name_node("dt", a), a),
		a,
	)
	give_up := with_node(
		name_node("self", a),
		a,
		recfield_spec("ai", variant_unit_node("Hunt", "Patrol", a)),
		recfield_spec("search_t", hf_fixed_node(to_fixed(0), a)),
	)
	body[1] = if_return_node(binary_node("le", name_node("t", a), hf_fixed_node(to_fixed(0), a), a), give_up, a)
	keep := with_node(
		name_node("self", a),
		a,
		recfield_spec(
			"pos",
			call_node_h(
				a,
				"step_to",
				field_node_h(name_node("self", a), "pos", a),
				field_node_h(name_node("self", a), "last_seen", a),
				name_node("H_SPEED", a),
			),
		),
		recfield_spec("search_t", name_node("t", a)),
	)
	body[2] = return_node_h(keep, a)
	return Function_Decl{name = "seek", kind = .Fn, params = params, body = body}
}

@(private = "file")
think_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	params := make([]Param_Decl, 3, a)
	params[0] = Param_Decl{name = "self", type = "Hunter"}
	params[1] = Param_Decl{name = "players", type = "View[Player]"}
	params[2] = Param_Decl{name = "time", type = "Time"}
	emits := make([]string, 1, a)
	emits[0] = "Hunter"

	body := make([]Node, 2, a)
	body[0] = let_node(
		"seen",
		call_node_h(a, "visible", field_node_h(name_node("self", a), "pos", a), name_node("players", a)),
		a,
	)
	patrol_arm := bare_variant_arm("Hunt", "Patrol", a)
	patrol_body := call_node_h(a, "patrol", name_node("self", a), name_node("seen", a))
	chase_arm := bare_variant_arm("Hunt", "Chase", a)
	chase_body := call_node_h(a, "chase", name_node("self", a), name_node("seen", a))
	search_arm := bare_variant_arm("Hunt", "Search", a)
	search_body := call_node_h(
		a,
		"search",
		name_node("self", a),
		name_node("seen", a),
		field_node_h(name_node("time", a), "dt", a),
	)
	match := match_node(
		field_node_h(name_node("self", a), "ai", a),
		a,
		patrol_arm,
		patrol_body,
		chase_arm,
		chase_body,
		search_arm,
		search_body,
	)
	body[1] = return_node_h(match, a)
	return Behavior_Decl{name = "think", on_thing = "Hunter", stage = "ai", params = params, emits = emits, body = body}
}

@(private = "file")
hunter_seen_params :: proc(a := context.allocator) -> []Param_Decl {
	params := make([]Param_Decl, 2, a)
	params[0] = Param_Decl{name = "self", type = "Hunter"}
	params[1] = Param_Decl{name = "seen", type = "Option[Vec2]"}
	return params
}

hunt_call_two :: proc(interp: ^Interp, name: string, a, b: Value) -> (result: Value, ok: bool) {
	fn := program_function(interp.program, name)
	if fn == nil || len(fn.params) != 2 {
		return nil, false
	}
	scope := Env{names = make(map[string]Value, interp.allocator)}
	scope.names[fn.params[0].name] = a
	scope.names[fn.params[1].name] = b
	return eval_body(interp, fn.body, &scope)
}

hunt_call_three :: proc(interp: ^Interp, name: string, a, b, c: Value) -> (result: Value, ok: bool) {
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
vec2_spawn :: proc(a: Runtime_Allocator, name: string, x, y: Fixed) -> []Spawn_Field {
	fields := make([]Spawn_Field, 1, a)
	fields[0] = Spawn_Field{name = name, kind = .Vec2, vec2_x = x, vec2_y = y}
	return fields
}

@(private = "file")
hunter_spawn :: proc(a: Runtime_Allocator, x, y: Fixed) -> []Spawn_Field {
	fields := make([]Spawn_Field, 2, a)
	fields[0] = Spawn_Field{name = "pos", kind = .Vec2, vec2_x = x, vec2_y = y}
	fields[1] = Spawn_Field{name = "home", kind = .Vec2, vec2_x = x, vec2_y = y}
	return fields
}

@(private = "file")
const_fn :: proc(name: string, value: Node, a := context.allocator) -> Function_Decl {
	body := make([]Node, 1, a)
	body[0] = return_node_h(value, a)
	return Function_Decl{name = name, kind = .Const, body = body}
}

@(private = "file")
hf_fixed_node :: proc(f: Fixed, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = encode_fixed_bits(f, a)
	return Node{kind = .Fixed, fields = fields}
}

@(private = "file")
name_node :: proc(name: string, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = name
	return Node{kind = .Name, fields = fields}
}

@(private = "file")
field_node_h :: proc(recv: Node, field: string, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = field
	children := make([]Node, 1, a)
	children[0] = recv
	return Node{kind = .Field, fields = fields, children = children}
}

@(private = "file")
binary_node :: proc(op: string, lhs, rhs: Node, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = op
	children := make([]Node, 2, a)
	children[0] = lhs
	children[1] = rhs
	return Node{kind = .Binary, fields = fields, children = children}
}

@(private = "file")
call_node_h :: proc(a: Runtime_Allocator, callee: string, args: ..Node) -> Node {
	children := make([]Node, len(args) + 1, a)
	children[0] = name_node(callee, a)
	for arg, i in args {
		children[i + 1] = arg
	}
	return Node{kind = .Call, children = children}
}

@(private = "file")
lambda_node_h :: proc(a: Runtime_Allocator, body: Node, params: ..string) -> Node {
	fields := make([]string, len(params) + 1, a)
	fields[0] = fmt_count(len(params), a)
	for p, i in params {
		fields[i + 1] = p
	}
	children := make([]Node, 1, a)
	children[0] = body
	return Node{kind = .Lambda, fields = fields, children = children}
}

@(private = "file")
variant_unit_node :: proc(enum_type, case_name: string, a := context.allocator) -> Node {
	fields := make([]string, 3, a)
	fields[0] = enum_type
	fields[1] = case_name
	fields[2] = "false"
	return Node{kind = .Variant, fields = fields}
}

@(private = "file")
variant_payload_node :: proc(enum_type, case_name: string, payload: Node, a := context.allocator) -> Node {
	fields := make([]string, 3, a)
	fields[0] = enum_type
	fields[1] = case_name
	fields[2] = "true"
	children := make([]Node, 1, a)
	children[0] = payload
	return Node{kind = .Variant, fields = fields, children = children}
}

@(private = "file")
with_node :: proc(base: Node, a: Runtime_Allocator, specs: ..Recfield_Spec_H) -> Node {
	children := make([]Node, len(specs) + 1, a)
	children[0] = base
	for spec, i in specs {
		children[i + 1] = recfield_node_h(spec, a)
	}
	return Node{kind = .With, children = children}
}

@(private = "file")
Recfield_Spec_H :: struct {
	name:  string,
	value: Node,
}

@(private = "file")
recfield_spec :: proc(name: string, value: Node) -> Recfield_Spec_H {
	return Recfield_Spec_H{name = name, value = value}
}

@(private = "file")
recfield_node_h :: proc(spec: Recfield_Spec_H, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = spec.name
	children := make([]Node, 1, a)
	children[0] = spec.value
	return Node{kind = .Recfield, fields = fields, children = children}
}

@(private = "file")
match_node :: proc(scrutinee: Node, a: Runtime_Allocator, arms_bodies: ..Node) -> Node {
	children := make([]Node, len(arms_bodies) + 1, a)
	children[0] = scrutinee
	for n, i in arms_bodies {
		children[i + 1] = n
	}
	return Node{kind = .Match, children = children}
}

@(private = "file")
variant_binds_arm :: proc(enum_type, case_name, binder: string, a := context.allocator) -> Node {
	fields := make([]string, 5, a)
	fields[0] = "variant_binds"
	fields[1] = enum_type
	fields[2] = case_name
	fields[3] = "1"
	fields[4] = binder
	return Node{kind = .Arm, fields = fields}
}

@(private = "file")
bare_variant_arm :: proc(enum_type, case_name: string, a := context.allocator) -> Node {
	fields := make([]string, 3, a)
	fields[0] = "bare_variant"
	fields[1] = enum_type
	fields[2] = case_name
	return Node{kind = .Arm, fields = fields}
}

@(private = "file")
let_node :: proc(name: string, value: Node, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = name
	children := make([]Node, 1, a)
	children[0] = value
	return Node{kind = .Let, fields = fields, children = children}
}

@(private = "file")
if_return_node :: proc(guard, value: Node, a := context.allocator) -> Node {
	children := make([]Node, 2, a)
	children[0] = guard
	children[1] = value
	return Node{kind = .If_Return, children = children}
}

@(private = "file")
return_node_h :: proc(value: Node, a := context.allocator) -> Node {
	children := make([]Node, 1, a)
	children[0] = value
	return Node{kind = .Return, children = children}
}

@(private = "file")
encode_fixed_bits :: proc(f: Fixed, a := context.allocator) -> string {
	buf := make([]u8, 24, a)
	return strconv.write_int(buf, i64(f), 10)
}

@(private = "file")
fmt_count :: proc(n: int, a := context.allocator) -> string {
	buf := make([]u8, 24, a)
	return strconv.write_int(buf, i64(n), 10)
}
