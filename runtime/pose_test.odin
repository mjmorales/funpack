package funpack_runtime

import "core:testing"

@(private = "file")
pose_tokens :: proc(tokens: ..string) -> []string {
	out := make([]string, len(tokens), context.temp_allocator)
	copy(out, tokens)
	return out
}

@(private = "file")
pose_kids :: proc(nodes: ..Node) -> []Node {
	out := make([]Node, len(nodes), context.temp_allocator)
	copy(out, nodes)
	return out
}

@(private = "file")
n_name :: proc(name: string) -> Node {
	return Node{kind = .Name, fields = pose_tokens(name)}
}

@(private = "file")
n_fixed :: proc(f: Fixed) -> Node {
	return Node{kind = .Fixed, fields = pose_tokens(aprint_int(i64(f), context.temp_allocator))}
}

@(private = "file")
n_variant :: proc(enum_type, case_name: string) -> Node {
	return Node{kind = .Variant, fields = pose_tokens(enum_type, case_name, "false")}
}

@(private = "file")
n_call :: proc(name: string, args: ..Node) -> Node {
	children := make([]Node, len(args) + 1, context.temp_allocator)
	children[0] = n_name(name)
	copy(children[1:], args)
	return Node{kind = .Call, children = children}
}

@(private = "file")
n_method :: proc(recv: Node, method: string, args: ..Node) -> Node {
	field := Node{kind = .Field, fields = pose_tokens(method), children = pose_kids(recv)}
	children := make([]Node, len(args) + 1, context.temp_allocator)
	children[0] = field
	copy(children[1:], args)
	return Node{kind = .Call, children = children}
}

@(private = "file")
n_binary :: proc(op: string, lhs, rhs: Node) -> Node {
	return Node{kind = .Binary, fields = pose_tokens(op), children = pose_kids(lhs, rhs)}
}

@(private = "file")
n_unary :: proc(op: string, operand: Node) -> Node {
	return Node{kind = .Unary, fields = pose_tokens(op), children = pose_kids(operand)}
}

@(private = "file")
n_field :: proc(recv: Node, field: string) -> Node {
	return Node{kind = .Field, fields = pose_tokens(field), children = pose_kids(recv)}
}

@(private = "file")
n_recfield :: proc(name: string, value: Node) -> Node {
	return Node{kind = .Recfield, fields = pose_tokens(name), children = pose_kids(value)}
}

@(private = "file")
n_record :: proc(type_name: string, fields: ..Node) -> Node {
	return Node{kind = .Record, fields = pose_tokens(type_name), children = pose_kids(..fields)}
}

@(private = "file")
n_list :: proc(elems: ..Node) -> Node {
	return Node{kind = .List, children = pose_kids(..elems)}
}

@(private = "file")
n_rot_x :: proc(angle: Node) -> Node {return n_call("rot_x", angle)}

@(private = "file")
n_up :: proc(d: Node) -> Node {return n_call("up", d)}

@(private = "file")
n_pose_empty :: proc() -> Node {
	return n_method(n_name("Pose"), "empty")
}

@(private = "file")
fixed_lit :: proc(num, den: i64) -> Fixed {
	return fixed_div(to_fixed(num), to_fixed(den))
}

@(private = "file")
make_pose_interp :: proc(program: ^Program, version: ^World_Version, t: Fixed) -> Interp {
	time_fields := make(map[string]Value, context.temp_allocator)
	time_fields["dt"] = fixed_div(to_fixed(1), to_fixed(60))
	time_fields["t"] = t
	time := Record_Value{type_name = "Time", fields = time_fields}
	return new_interp(program, version, nil, empty(), time, context.temp_allocator)
}

@(private = "file")
pose_program :: proc() -> Program {
	walk_weight := Function_Decl {
		name = "walk_weight",
		kind = .Fn,
		params = pose_param_slice({"speed", "Fixed"}),
		return_type = "Fixed",
		body = pose_body(
			Node {
				kind = .Return,
				children = pose_kids(
					n_call(
						"clamp",
						n_binary("mul", n_name("speed"), n_fixed(to_fixed(2))),
						n_fixed(Fixed(0)),
						n_fixed(FIXED_ONE),
					),
				),
			},
		),
	}

	idle_bob := n_binary(
		"mul",
		n_call("sin", n_binary("mul", n_name("t"), n_fixed(to_fixed(2)))),
		n_fixed(fixed_lit(2, 10)),
	)
	pose_idle := Function_Decl {
		name = "pose_idle",
		kind = .Fn,
		params = pose_param_slice({"t", "Fixed"}),
		return_type = "Pose",
		body = pose_body(
			Node {
				kind = .Return,
				children = pose_kids(
					n_method(n_pose_empty(), "set", n_variant("Bone", "Torso"), n_up(idle_bob)),
				),
			},
		),
	}

	let_s := Node {
		kind = .Let,
		fields = pose_tokens("s"),
		children = pose_kids(
			n_binary("mul", n_call("sin", n_name("phase")), n_fixed(fixed_lit(5, 10))),
		),
	}
	walk_chain := n_method(
		n_method(
			n_method(
				n_method(
					n_method(n_pose_empty(), "set", n_variant("Bone", "LUpperLeg"), n_rot_x(n_name("s"))),
					"set",
					n_variant("Bone", "RUpperLeg"),
					n_rot_x(n_unary("neg", n_name("s"))),
				),
				"set",
				n_variant("Bone", "LUpperArm"),
				n_rot_x(n_unary("neg", n_binary("mul", n_name("s"), n_fixed(fixed_lit(6, 10))))),
			),
			"set",
			n_variant("Bone", "RUpperArm"),
			n_rot_x(n_binary("mul", n_name("s"), n_fixed(fixed_lit(6, 10)))),
		),
		"set",
		n_variant("Bone", "Torso"),
		n_up(
			n_binary(
				"mul",
				n_call("sin", n_binary("mul", n_name("phase"), n_fixed(to_fixed(2)))),
				n_fixed(fixed_lit(3, 10)),
			),
		),
	)
	pose_walk := Function_Decl {
		name = "pose_walk",
		kind = .Fn,
		params = pose_param_slice({"phase", "Fixed"}, {"speed", "Fixed"}),
		return_type = "Pose",
		body = pose_body(let_s, Node{kind = .Return, children = pose_kids(walk_chain)}),
	}

	krognid_skeleton := Function_Decl {
		name = "krognid_skeleton",
		kind = .Fn,
		return_type = "Skeleton",
		body = pose_body(
			Node{kind = .Return, children = pose_kids(n_method(n_name("Skeleton"), "humanoid"))},
		),
	}

	parts_chain := n_method(
		n_method(
			n_method(
				n_method(
					n_method(
						n_method(
							n_method(n_method(n_name("PartSet"), "empty"), "bind", n_variant("Slot", "Torso"), n_mesh("krognid_torso")),
							"bind",
							n_variant("Slot", "Head"),
							n_mesh("krognid_head"),
						),
						"bind",
						n_variant("Slot", "LUpperArm"),
						n_mesh("krognid_upper_arm"),
					),
					"bind",
					n_variant("Slot", "LLowerArm"),
					n_mesh("krognid_lower_arm"),
				),
				"bind",
				n_variant("Slot", "LUpperLeg"),
				n_mesh("krognid_upper_leg"),
			),
			"bind",
			n_variant("Slot", "LLowerLeg"),
			n_mesh("krognid_lower_leg"),
		),
		"mirror",
		n_variant("Side", "L"),
		n_variant("Side", "R"),
	)
	krognid_parts := Function_Decl {
		name = "krognid_parts",
		kind = .Fn,
		return_type = "PartSet",
		body = pose_body(Node{kind = .Return, children = pose_kids(parts_chain)}),
	}

	let_pose := Node {
		kind = .Let,
		fields = pose_tokens("pose"),
		children = pose_kids(
			n_method(
				n_name("Pose"),
				"blend",
				n_call("pose_idle", n_field(n_name("time"), "t")),
				n_call("pose_walk", n_field(n_name("self"), "phase"), n_field(n_name("self"), "speed")),
				n_call("walk_weight", n_field(n_name("self"), "speed")),
			),
		),
	}
	rigged := n_record(
		"Draw3::Rigged",
		n_recfield("skeleton", n_call("krognid_skeleton")),
		n_recfield("parts", n_call("krognid_parts")),
		n_recfield("pose", n_name("pose")),
		n_recfield("at", n_field(n_name("self"), "pos")),
	)
	draw_krognid := Function_Decl {
		name = "draw_krognid",
		kind = .Fn,
		params = pose_param_slice({"self", "Krognid"}, {"time", "Time"}),
		return_type = "[Draw3]",
		body = pose_body(let_pose, Node{kind = .Return, children = pose_kids(n_list(rigged))}),
	}

	functions := make([]Function_Decl, 6, context.temp_allocator)
	functions[0] = walk_weight
	functions[1] = pose_idle
	functions[2] = pose_walk
	functions[3] = krognid_skeleton
	functions[4] = krognid_parts
	functions[5] = draw_krognid
	return Program{schema_version = ARTIFACT_SCHEMA_VERSION, functions = functions}
}

@(private = "file")
n_string :: proc(text: string) -> Node {
	token := aprint_concat("L", aprint_int(i64(len(text)), context.temp_allocator), ":", text)
	return Node{kind = .String, fields = pose_tokens(token)}
}

@(private = "file")
aprint_concat :: proc(parts: ..string) -> string {
	out := make([dynamic]u8, 0, context.temp_allocator)
	for p in parts {
		for c in transmute([]u8)p {
			append(&out, c)
		}
	}
	return string(out[:])
}

@(private = "file")
n_mesh :: proc(asset: string) -> Node {
	return n_record("MeshHandle", n_recfield("name", n_string(asset)))
}

@(private = "file")
pose_param_slice :: proc(pairs: ..[2]string) -> []Param_Decl {
	out := make([]Param_Decl, len(pairs), context.temp_allocator)
	for pair, i in pairs {
		out[i] = Param_Decl{name = pair[0], type = pair[1]}
	}
	return out
}

@(private = "file")
pose_body :: proc(stmts: ..Node) -> []Node {
	out := make([]Node, len(stmts), context.temp_allocator)
	copy(out, stmts)
	return out
}

@(private = "file")
pose_version :: proc(program: ^Program) -> World_Version {
	return initial_version(new_world(program^, context.temp_allocator), context.temp_allocator)
}

@(private = "file")
eval_in :: proc(interp: ^Interp, node: ^Node, bindings: ..struct{name: string, value: Value}) -> (Value, bool) {
	env := Env{names = make(map[string]Value, context.temp_allocator)}
	for b in bindings {
		env.names[b.name] = b.value
	}
	return eval(interp, node, &env)
}

@(test)
test_pose_builders_eval :: proc(t: ^testing.T) {
	program := pose_program()
	version := pose_version(&program)
	interp := make_pose_interp(&program, &version, Fixed(0))

	walk0 := n_method(
		n_call("pose_walk", n_fixed(Fixed(0)), n_fixed(FIXED_ONE)),
		"get",
		n_variant("Bone", "LUpperLeg"),
	)
	leg, leg_ok := eval_in(&interp, &walk0)
	testing.expect(t, leg_ok)
	testing.expect(t, values_equal(leg, transform_rot_x(Fixed(0))))
	testing.expect(t, values_equal(leg, transform_identity()))

	set_get := n_method(
		n_method(n_pose_empty(), "set", n_variant("Bone", "Torso"), n_up(n_fixed(fixed_lit(3, 10)))),
		"get",
		n_variant("Bone", "Torso"),
	)
	torso, torso_ok := eval_in(&interp, &set_get)
	testing.expect(t, torso_ok)
	testing.expect(t, values_equal(torso, transform_up(fixed_lit(3, 10))))

	undriven := n_method(
		n_method(n_pose_empty(), "set", n_variant("Bone", "Torso"), n_up(n_fixed(fixed_lit(3, 10)))),
		"get",
		n_variant("Bone", "Head"),
	)
	head, head_ok := eval_in(&interp, &undriven)
	testing.expect(t, head_ok)
	testing.expect(t, values_equal(head, transform_rot_x(Fixed(0))))

	ww_full := n_call("walk_weight", n_fixed(FIXED_ONE))
	full, full_ok := eval_in(&interp, &ww_full)
	testing.expect(t, full_ok)
	testing.expect_value(t, full.(Fixed), FIXED_ONE)

	ww_rest := n_call("walk_weight", n_fixed(Fixed(0)))
	rest, rest_ok := eval_in(&interp, &ww_rest)
	testing.expect(t, rest_ok)
	testing.expect_value(t, rest.(Fixed), Fixed(0))

	bad_set := n_method(n_pose_empty(), "set", n_fixed(Fixed(0)), n_up(n_fixed(Fixed(0))))
	_, bad_ok := eval_in(&interp, &bad_set)
	testing.expect(t, !bad_ok)
}

@(test)
test_pose_blend_and_layer :: proc(t: ^testing.T) {
	program := pose_program()
	version := pose_version(&program)
	interp := make_pose_interp(&program, &version, Fixed(0))

	blend0 := n_method(
		n_method(
			n_name("Pose"),
			"blend",
			n_call("pose_walk", n_fixed(Fixed(0)), n_fixed(FIXED_ONE)),
			n_call("pose_idle", n_fixed(Fixed(0))),
			n_fixed(Fixed(0)),
		),
		"get",
		n_variant("Bone", "LUpperLeg"),
	)
	b0, b0_ok := eval_in(&interp, &blend0)
	testing.expect(t, b0_ok)
	testing.expect(t, values_equal(b0, transform_rot_x(Fixed(0))))

	blend1 := n_method(
		n_method(
			n_name("Pose"),
			"blend",
			n_pose_empty(),
			n_method(n_pose_empty(), "set", n_variant("Bone", "Torso"), n_up(n_fixed(fixed_lit(3, 10)))),
			n_fixed(FIXED_ONE),
		),
		"get",
		n_variant("Bone", "Torso"),
	)
	b1, b1_ok := eval_in(&interp, &blend1)
	testing.expect(t, b1_ok)
	testing.expect(t, values_equal(b1, transform_up(fixed_lit(3, 10))))

	blend_disjoint := n_method(
		n_method(
			n_name("Pose"),
			"blend",
			n_method(n_pose_empty(), "set", n_variant("Bone", "LUpperLeg"), n_rot_x(n_fixed(Fixed(0)))),
			n_method(n_pose_empty(), "set", n_variant("Bone", "Torso"), n_up(n_fixed(fixed_lit(5, 10)))),
			n_fixed(Fixed(0)),
		),
		"get",
		n_variant("Bone", "LUpperLeg"),
	)
	bd, bd_ok := eval_in(&interp, &blend_disjoint)
	testing.expect(t, bd_ok)
	testing.expect(t, values_equal(bd, transform_rot_x(Fixed(0))))

	layer_wins := n_method(
		n_method(
			n_name("Pose"),
			"layer",
			n_method(n_pose_empty(), "set", n_variant("Bone", "Torso"), n_up(n_fixed(fixed_lit(1, 10)))),
			n_method(n_pose_empty(), "set", n_variant("Bone", "Torso"), n_up(n_fixed(fixed_lit(5, 10)))),
		),
		"get",
		n_variant("Bone", "Torso"),
	)
	lw, lw_ok := eval_in(&interp, &layer_wins)
	testing.expect(t, lw_ok)
	testing.expect(t, values_equal(lw, transform_up(fixed_lit(5, 10))))

	layer_through := n_method(
		n_method(
			n_name("Pose"),
			"layer",
			n_method(n_pose_empty(), "set", n_variant("Bone", "LUpperLeg"), n_rot_x(n_fixed(Fixed(0)))),
			n_method(n_pose_empty(), "set", n_variant("Bone", "Torso"), n_up(n_fixed(fixed_lit(5, 10)))),
		),
		"get",
		n_variant("Bone", "LUpperLeg"),
	)
	lt, lt_ok := eval_in(&interp, &layer_through)
	testing.expect(t, lt_ok)
	testing.expect(t, values_equal(lt, transform_rot_x(Fixed(0))))

	blend_unclamped := n_method(
		n_method(
			n_name("Pose"),
			"blend",
			n_method(n_pose_empty(), "set", n_variant("Bone", "Torso"), n_rot_x(n_fixed(Fixed(0)))),
			n_method(n_pose_empty(), "set", n_variant("Bone", "Torso"), n_rot_x(n_fixed(Fixed(0)))),
			n_fixed(to_fixed(2)),
		),
		"get",
		n_variant("Bone", "Torso"),
	)
	bu, bu_ok := eval_in(&interp, &blend_unclamped)
	testing.expect(t, bu_ok)
	testing.expect(t, values_equal(bu, transform_rot_x(Fixed(0))))
}

@(test)
test_pose_blend_absent_bone_rests_at_interior_weight :: proc(t: ^testing.T) {
	program := pose_program()
	version := pose_version(&program)
	interp := make_pose_interp(&program, &version, Fixed(0))

	half := fixed_lit(5, 10)
	drive := fixed_lit(4, 10)
	blend := n_method(
		n_method(
			n_name("Pose"),
			"blend",
			n_method(n_pose_empty(), "set", n_variant("Bone", "LUpperLeg"), n_up(n_fixed(drive))),
			n_method(n_pose_empty(), "set", n_variant("Bone", "Torso"), n_up(n_fixed(fixed_lit(5, 10)))),
			n_fixed(half),
		),
		"get",
		n_variant("Bone", "LUpperLeg"),
	)
	got, ok := eval_in(&interp, &blend)
	testing.expect(t, ok)
	want := transform_blend(transform_up(drive), transform_identity(), half)
	testing.expect(t, values_equal(got, want))
}

@(test)
test_draw_krognid_folds_to_rigged :: proc(t: ^testing.T) {
	program := pose_program()
	version := pose_version(&program)
	interp := make_pose_interp(&program, &version, Fixed(0))

	self_fields := make(map[string]Value, context.temp_allocator)
	self_fields["player"] = Variant_Value{enum_type = "PlayerId", case_name = "P1"}
	self_fields["pos"] = Vec3{x = to_fixed(25), y = Fixed(0), z = to_fixed(25)}
	self_fields["intent"] = Vec2{x = Fixed(0), y = Fixed(0)}
	self_fields["phase"] = fixed_lit(1, 2)
	self_fields["speed"] = fixed_lit(1, 2)
	self := Record_Value{type_name = "Krognid", fields = self_fields}

	draw := program_function(&program, "draw_krognid")
	testing.expect(t, draw != nil)

	scope := Env{names = make(map[string]Value, context.temp_allocator)}
	scope.names["self"] = self
	scope.names["time"] = interp.time
	draws, draws_ok := eval_body(&interp, draw.body, &scope)
	testing.expect(t, draws_ok)

	list, is_list := draws.(List_Value)
	testing.expect(t, is_list)
	testing.expect_value(t, len(list.elements), 1)
	if len(list.elements) != 1 {
		return
	}

	rigged, is_rigged := list.elements[0].(Record_Value)
	testing.expect(t, is_rigged)
	testing.expect_value(t, rigged.type_name, "Draw3::Rigged")

	at, at_present := rigged.fields["at"]
	testing.expect(t, at_present)
	testing.expect(t, values_equal(at, Vec3{x = to_fixed(25), y = Fixed(0), z = to_fixed(25)}))

	skeleton, sk_present := rigged.fields["skeleton"]
	testing.expect(t, sk_present)
	sk_handle, sk_is_handle := skeleton.(Handle_Value)
	testing.expect(t, sk_is_handle)
	testing.expect_value(t, sk_handle.kind, "Skeleton")
	testing.expect_value(t, sk_handle.factory, "humanoid")
	testing.expect_value(t, len(sk_handle.ops), 0)
	testing.expect(t, values_equal(skeleton, Handle_Value{kind = "Skeleton", factory = "humanoid", ops = make([]Handle_Op, 0, context.temp_allocator)}))

	parts, pt_present := rigged.fields["parts"]
	testing.expect(t, pt_present)
	pt_handle, pt_is_handle := parts.(Handle_Value)
	testing.expect(t, pt_is_handle)
	testing.expect_value(t, pt_handle.kind, "PartSet")
	testing.expect_value(t, pt_handle.factory, "empty")
	testing.expect_value(t, len(pt_handle.ops), 7)
	if len(pt_handle.ops) == 7 {
		testing.expect_value(t, pt_handle.ops[0].method, "bind")
		testing.expect_value(t, pt_handle.ops[0].args[0], "Torso")
		testing.expect_value(t, pt_handle.ops[0].args[1], "krognid_torso")
		testing.expect_value(t, pt_handle.ops[6].method, "mirror")
		testing.expect_value(t, pt_handle.ops[6].args[0], "L")
		testing.expect_value(t, pt_handle.ops[6].args[1], "R")
	}

	pose, pose_present := rigged.fields["pose"]
	testing.expect(t, pose_present)
	pose_value, pose_is := pose.(Pose_Value)
	testing.expect(t, pose_is)
	testing.expect_value(t, len(pose_value.bones), 5)
	for bone in ([]string{"Torso", "LUpperLeg", "RUpperLeg", "LUpperArm", "RUpperArm"}) {
		_, found := pose_bone_transform(pose_value.bones, bone)
		testing.expectf(t, found, "blended pose drives bone %s", bone)
	}

	idle_call := n_call("pose_idle", n_fixed(Fixed(0)))
	walk_call := n_call("pose_walk", n_fixed(fixed_lit(1, 2)), n_fixed(fixed_lit(1, 2)))
	ww_call := n_call("walk_weight", n_fixed(fixed_lit(1, 2)))
	idle, idle_ok := eval_in(&interp, &idle_call)
	walk, walk_ok := eval_in(&interp, &walk_call)
	ww, ww_ok := eval_in(&interp, &ww_call)
	testing.expect(t, idle_ok && walk_ok && ww_ok)
	expected_pose := eval_pose_blend(&interp, idle.(Pose_Value), walk.(Pose_Value), ww.(Fixed))
	testing.expect(t, values_equal(pose, expected_pose))
}
