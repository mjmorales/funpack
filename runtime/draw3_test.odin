package funpack_runtime

import "core:testing"

@(private = "file")
d3_tokens :: proc(tokens: ..string) -> []string {
	out := make([]string, len(tokens), context.temp_allocator)
	copy(out, tokens)
	return out
}

@(private = "file")
d3_kids :: proc(nodes: ..Node) -> []Node {
	out := make([]Node, len(nodes), context.temp_allocator)
	copy(out, nodes)
	return out
}

@(private = "file")
d3_name :: proc(name: string) -> Node {
	return Node{kind = .Name, fields = d3_tokens(name)}
}

@(private = "file")
d3_fixed :: proc(f: Fixed) -> Node {
	return Node{kind = .Fixed, fields = d3_tokens(aprint_int(i64(f), context.temp_allocator))}
}

@(private = "file")
d3_variant :: proc(enum_type, case_name: string) -> Node {
	return Node{kind = .Variant, fields = d3_tokens(enum_type, case_name, "false")}
}

@(private = "file")
d3_recfield :: proc(name: string, value: Node) -> Node {
	return Node{kind = .Recfield, fields = d3_tokens(name), children = d3_kids(value)}
}

@(private = "file")
d3_record :: proc(type_name: string, fields: ..Node) -> Node {
	return Node{kind = .Record, fields = d3_tokens(type_name), children = d3_kids(..fields)}
}

@(private = "file")
d3_list :: proc(elems: ..Node) -> Node {
	return Node{kind = .List, children = d3_kids(..elems)}
}

@(private = "file")
d3_field :: proc(recv: Node, field: string) -> Node {
	return Node{kind = .Field, fields = d3_tokens(field), children = d3_kids(recv)}
}

@(private = "file")
d3_vec3 :: proc(x, y, z: Fixed) -> Node {
	return d3_record(
		"Vec3",
		d3_recfield("x", d3_fixed(x)),
		d3_recfield("y", d3_fixed(y)),
		d3_recfield("z", d3_fixed(z)),
	)
}

@(private = "file")
d3_vec2 :: proc(x, y: Fixed) -> Node {
	return d3_record("Vec2", d3_recfield("x", d3_fixed(x)), d3_recfield("y", d3_fixed(y)))
}

@(private = "file")
d3_program :: proc() -> Program {
	camera := d3_record(
		"Draw3::Camera",
		d3_recfield("eye", d3_vec3(to_fixed(25), to_fixed(40), fixed_neg(to_fixed(30)))),
		d3_recfield("at", d3_vec3(to_fixed(25), Fixed(0), to_fixed(25))),
		d3_recfield("fov", d3_fixed(to_fixed(60))),
	)
	light := d3_record(
		"Draw3::Light",
		d3_recfield(
			"dir",
			d3_vec3(
				fixed_neg(d3_frac(3, 10)),
				fixed_neg(to_fixed(1)),
				fixed_neg(d3_frac(2, 10)),
			),
		),
		d3_recfield("color", d3_variant("Color", "White")),
	)
	plane := d3_record(
		"Draw3::Plane",
		d3_recfield("at", d3_vec3(to_fixed(25), Fixed(0), to_fixed(25))),
		d3_recfield("size", d3_vec2(to_fixed(50), to_fixed(50))),
		d3_recfield("color", d3_variant("Color", "Gray")),
	)
	draw_scene := Function_Decl {
		name        = "draw_scene",
		kind        = .Fn,
		params      = d3_params({"self", "Field"}),
		return_type = "[Draw3]",
		body        = d3_body(
			Node{kind = .Return, children = d3_kids(d3_list(camera, light, plane))},
		),
	}

	let_pose := Node {
		kind     = .Let,
		fields   = d3_tokens("pose"),
		children = d3_kids(
			d3_method(
				d3_name("Pose"),
				"blend",
				d3_call("pose_idle", d3_field(d3_name("time"), "t")),
				d3_call("pose_walk", d3_field(d3_name("self"), "phase"), d3_field(d3_name("self"), "speed")),
				d3_call("walk_weight", d3_field(d3_name("self"), "speed")),
			),
		),
	}
	rigged := d3_record(
		"Draw3::Rigged",
		d3_recfield("skeleton", d3_call("krognid_skeleton")),
		d3_recfield("parts", d3_call("krognid_parts")),
		d3_recfield("pose", d3_name("pose")),
		d3_recfield("at", d3_field(d3_name("self"), "pos")),
	)
	draw_krognid := Function_Decl {
		name        = "draw_krognid",
		kind        = .Fn,
		params      = d3_params({"self", "Krognid"}, {"time", "Time"}),
		return_type = "[Draw3]",
		body        = d3_body(let_pose, Node{kind = .Return, children = d3_kids(d3_list(rigged))}),
	}

	helpers := d3_pose_helpers()
	functions := make([]Function_Decl, len(helpers) + 2, context.temp_allocator)
	copy(functions, helpers)
	functions[len(helpers)] = draw_scene
	functions[len(helpers) + 1] = draw_krognid
	return Program{schema_version = ARTIFACT_SCHEMA_VERSION, functions = functions}
}

@(private = "file")
d3_pose_helpers :: proc() -> []Function_Decl {
	walk_weight := Function_Decl {
		name        = "walk_weight",
		kind        = .Fn,
		params      = d3_params({"speed", "Fixed"}),
		return_type = "Fixed",
		body        = d3_body(
			Node {
				kind     = .Return,
				children = d3_kids(
					d3_call(
						"clamp",
						d3_binary("mul", d3_name("speed"), d3_fixed(to_fixed(2))),
						d3_fixed(Fixed(0)),
						d3_fixed(FIXED_ONE),
					),
				),
			},
		),
	}

	idle_bob := d3_binary(
		"mul",
		d3_call("sin", d3_binary("mul", d3_name("t"), d3_fixed(to_fixed(2)))),
		d3_fixed(d3_frac(2, 10)),
	)
	pose_idle := Function_Decl {
		name        = "pose_idle",
		kind        = .Fn,
		params      = d3_params({"t", "Fixed"}),
		return_type = "Pose",
		body        = d3_body(
			Node {
				kind     = .Return,
				children = d3_kids(
					d3_method(d3_pose_empty(), "set", d3_variant("Bone", "Torso"), d3_call("up", idle_bob)),
				),
			},
		),
	}

	let_s := Node {
		kind     = .Let,
		fields   = d3_tokens("s"),
		children = d3_kids(d3_binary("mul", d3_call("sin", d3_name("phase")), d3_fixed(d3_frac(5, 10)))),
	}
	walk_chain := d3_method(
		d3_method(
			d3_method(
				d3_method(
					d3_method(d3_pose_empty(), "set", d3_variant("Bone", "LUpperLeg"), d3_call("rot_x", d3_name("s"))),
					"set",
					d3_variant("Bone", "RUpperLeg"),
					d3_call("rot_x", d3_unary("neg", d3_name("s"))),
				),
				"set",
				d3_variant("Bone", "LUpperArm"),
				d3_call("rot_x", d3_unary("neg", d3_binary("mul", d3_name("s"), d3_fixed(d3_frac(6, 10))))),
			),
			"set",
			d3_variant("Bone", "RUpperArm"),
			d3_call("rot_x", d3_binary("mul", d3_name("s"), d3_fixed(d3_frac(6, 10)))),
		),
		"set",
		d3_variant("Bone", "Torso"),
		d3_call("up", d3_binary("mul", d3_call("sin", d3_binary("mul", d3_name("phase"), d3_fixed(to_fixed(2)))), d3_fixed(d3_frac(3, 10)))),
	)
	pose_walk := Function_Decl {
		name        = "pose_walk",
		kind        = .Fn,
		params      = d3_params({"phase", "Fixed"}, {"speed", "Fixed"}),
		return_type = "Pose",
		body        = d3_body(let_s, Node{kind = .Return, children = d3_kids(walk_chain)}),
	}

	krognid_skeleton := Function_Decl {
		name        = "krognid_skeleton",
		kind        = .Fn,
		return_type = "Skeleton",
		body        = d3_body(
			Node{kind = .Return, children = d3_kids(d3_method(d3_name("Skeleton"), "humanoid"))},
		),
	}

	parts_chain := d3_method(
		d3_method(
			d3_method(d3_name("PartSet"), "empty"),
			"bind",
			d3_variant("Slot", "Torso"),
			d3_call("mesh", d3_string("krognid_torso")),
		),
		"mirror",
		d3_variant("Side", "L"),
		d3_variant("Side", "R"),
	)
	krognid_parts := Function_Decl {
		name        = "krognid_parts",
		kind        = .Fn,
		return_type = "PartSet",
		body        = d3_body(Node{kind = .Return, children = d3_kids(parts_chain)}),
	}

	out := make([]Function_Decl, 5, context.temp_allocator)
	out[0] = walk_weight
	out[1] = pose_idle
	out[2] = pose_walk
	out[3] = krognid_skeleton
	out[4] = krognid_parts
	return out
}

@(private = "file")
d3_call :: proc(name: string, args: ..Node) -> Node {
	children := make([]Node, len(args) + 1, context.temp_allocator)
	children[0] = d3_name(name)
	copy(children[1:], args)
	return Node{kind = .Call, children = children}
}

@(private = "file")
d3_method :: proc(recv: Node, method: string, args: ..Node) -> Node {
	field := Node{kind = .Field, fields = d3_tokens(method), children = d3_kids(recv)}
	children := make([]Node, len(args) + 1, context.temp_allocator)
	children[0] = field
	copy(children[1:], args)
	return Node{kind = .Call, children = children}
}

@(private = "file")
d3_binary :: proc(op: string, lhs, rhs: Node) -> Node {
	return Node{kind = .Binary, fields = d3_tokens(op), children = d3_kids(lhs, rhs)}
}

@(private = "file")
d3_unary :: proc(op: string, operand: Node) -> Node {
	return Node{kind = .Unary, fields = d3_tokens(op), children = d3_kids(operand)}
}

@(private = "file")
d3_pose_empty :: proc() -> Node {
	return d3_method(d3_name("Pose"), "empty")
}

@(private = "file")
d3_string :: proc(text: string) -> Node {
	token := d3_concat("L", aprint_int(i64(len(text)), context.temp_allocator), ":", text)
	return Node{kind = .String, fields = d3_tokens(token)}
}

@(private = "file")
d3_concat :: proc(parts: ..string) -> string {
	out := make([dynamic]u8, 0, context.temp_allocator)
	for p in parts {
		for c in transmute([]u8)p {
			append(&out, c)
		}
	}
	return string(out[:])
}

@(private = "file")
d3_frac :: proc(num, den: i64) -> Fixed {
	return fixed_div(to_fixed(num), to_fixed(den))
}

@(private = "file")
d3_params :: proc(pairs: ..[2]string) -> []Param_Decl {
	out := make([]Param_Decl, len(pairs), context.temp_allocator)
	for pair, i in pairs {
		out[i] = Param_Decl{name = pair[0], type = pair[1]}
	}
	return out
}

@(private = "file")
d3_body :: proc(stmts: ..Node) -> []Node {
	out := make([]Node, len(stmts), context.temp_allocator)
	copy(out, stmts)
	return out
}

@(private = "file")
d3_interp :: proc(program: ^Program, version: ^World_Version, t: Fixed) -> Interp {
	time_fields := make(map[string]Value, context.temp_allocator)
	time_fields["dt"] = fixed_div(to_fixed(1), to_fixed(60))
	time_fields["t"] = t
	time := Record_Value{type_name = "Time", fields = time_fields}
	return new_interp(program, version, nil, empty(), time, context.temp_allocator)
}

@(private = "file")
d3_krognid_self :: proc(pos: Vec3) -> Record_Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["player"] = Variant_Value{enum_type = "PlayerId", case_name = "P1"}
	fields["pos"] = pos
	fields["intent"] = Vec2{x = Fixed(0), y = Fixed(0)}
	fields["phase"] = fixed_div(to_fixed(1), to_fixed(2))
	fields["speed"] = fixed_div(to_fixed(1), to_fixed(2))
	return Record_Value{type_name = "Krognid", fields = fields}
}

@(private = "file")
d3_fold_scene :: proc(interp: ^Interp, program: ^Program, self: Record_Value) -> Draw_List {
	cmds := make([dynamic]Draw_Cmd, context.temp_allocator)

	scene_fn := program_function(program, "draw_scene")
	scene_scope := Env{names = make(map[string]Value, context.temp_allocator)}
	scene_scope.names["self"] = Record_Value {
		type_name = "Field",
		fields    = make(map[string]Value, context.temp_allocator),
	}
	scene_result, scene_ok := eval_body(interp, scene_fn.body, &scene_scope)
	if scene_ok {
		append_draw_commands(&cmds, scene_result)
	}

	krognid_fn := program_function(program, "draw_krognid")
	krognid_scope := Env{names = make(map[string]Value, context.temp_allocator)}
	krognid_scope.names["self"] = self
	krognid_scope.names["time"] = interp.time
	krognid_result, krognid_ok := eval_body(interp, krognid_fn.body, &krognid_scope)
	if krognid_ok {
		append_draw_commands(&cmds, krognid_result)
	}

	return Draw_List{cmds = cmds[:]}
}

@(test)
test_draw3_lowering :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	program := d3_program()
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)
	interp := d3_interp(&program, &version, Fixed(0))

	self := d3_krognid_self(Vec3{x = to_fixed(25), y = Fixed(0), z = to_fixed(25)})
	draw := d3_fold_scene(&interp, &program, self)

	if !testing.expect_value(t, len(draw.cmds), 4) {
		return
	}

	cam, cam_is := draw.cmds[0].(Draw3_Camera)
	testing.expect(t, cam_is)
	testing.expect(t, cam.eye == Vec3{x = to_fixed(25), y = to_fixed(40), z = fixed_neg(to_fixed(30))})
	testing.expect(t, cam.at == Vec3{x = to_fixed(25), y = Fixed(0), z = to_fixed(25)})
	testing.expect_value(t, cam.fov, to_fixed(60))

	light, light_is := draw.cmds[1].(Draw3_Light)
	testing.expect(t, light_is)
	testing.expect(t, light.dir == Vec3{x = fixed_neg(d3_frac(3, 10)), y = fixed_neg(to_fixed(1)), z = fixed_neg(d3_frac(2, 10))})
	testing.expect_value(t, light.color, named_color(.White))

	plane, plane_is := draw.cmds[2].(Draw3_Plane)
	testing.expect(t, plane_is)
	testing.expect(t, plane.at == Vec3{x = to_fixed(25), y = Fixed(0), z = to_fixed(25)})
	testing.expect(t, plane.size == Vec2{x = to_fixed(50), y = to_fixed(50)})
	testing.expect_value(t, plane.color, named_color(.Gray))

	rigged, rigged_is := draw.cmds[3].(Draw3_Rigged)
	testing.expect(t, rigged_is)
	testing.expect(t, rigged.at == Vec3{x = to_fixed(25), y = Fixed(0), z = to_fixed(25)})
	testing.expect_value(t, rigged.skeleton.kind, "Skeleton")
	testing.expect_value(t, rigged.skeleton.factory, "humanoid")
	testing.expect_value(t, rigged.parts.kind, "PartSet")
	testing.expect_value(t, len(rigged.parts.ops), 2)
	if len(rigged.parts.ops) == 2 {
		testing.expect_value(t, rigged.parts.ops[0].method, "bind")
		testing.expect_value(t, rigged.parts.ops[0].args[0], "Torso")
		testing.expect_value(t, rigged.parts.ops[0].args[1], "krognid_torso")
		testing.expect_value(t, rigged.parts.ops[1].method, "mirror")
	}
	testing.expect_value(t, len(rigged.pose.bones), 5)

	again := d3_fold_scene(&interp, &program, self)
	if testing.expect_value(t, len(again.cmds), len(draw.cmds)) {
		for cmd, i in draw.cmds {
			testing.expect(t, draw_cmd_equal(cmd, again.cmds[i]))
		}
	}
}

@(test)
test_draw3_digest_deterministic :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	program := d3_program()
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)
	interp := d3_interp(&program, &version, Fixed(0))

	at := Vec3{x = to_fixed(25), y = Fixed(0), z = to_fixed(25)}
	moved := Vec3{x = to_fixed(26), y = Fixed(0), z = to_fixed(25)}

	empty_version := World_Version{tick = 0, tables = nil}

	list_a := d3_fold_scene(&interp, &program, d3_krognid_self(at))
	list_b := d3_fold_scene(&interp, &program, d3_krognid_self(at))
	list_moved := d3_fold_scene(&interp, &program, d3_krognid_self(moved))

	digest_a := frame_digest(empty_version, list_a).digest
	digest_b := frame_digest(empty_version, list_b).digest
	testing.expect_value(t, digest_b, digest_a)

	bytes_a := frame_bytes(empty_version, list_a)
	bytes_b := frame_bytes(empty_version, list_b)
	testing.expect(t, d3_slices_equal(bytes_a, bytes_b))

	digest_moved := frame_digest(empty_version, list_moved).digest
	testing.expect(t, digest_moved != digest_a)

	plane_gray := Draw_List{cmds = []Draw_Cmd{Draw3_Plane{at = at, size = Vec2{to_fixed(50), to_fixed(50)}, color = named_color(.Gray)}}}
	plane_white := Draw_List{cmds = []Draw_Cmd{Draw3_Plane{at = at, size = Vec2{to_fixed(50), to_fixed(50)}, color = named_color(.White)}}}
	testing.expect(t, frame_digest(empty_version, plane_gray).digest != frame_digest(empty_version, plane_white).digest)

	testing.expect_value(t, u8(Cmd_Tag.Rect), 0)
	testing.expect_value(t, u8(Cmd_Tag.Text), 1)
	testing.expect_value(t, u8(Cmd_Tag.Camera), 2)
	testing.expect_value(t, u8(Cmd_Tag.Draw3_Camera), 3)
	testing.expect_value(t, u8(Cmd_Tag.Draw3_Light), 4)
	testing.expect_value(t, u8(Cmd_Tag.Draw3_Plane), 5)
	testing.expect_value(t, u8(Cmd_Tag.Draw3_Rigged), 6)
	testing.expect_value(t, FRAME_DIGEST_SCHEMA_VERSION, 11)

	rect_list := Draw_List{cmds = []Draw_Cmd{Draw_Rect{at = Vec2{to_fixed(8), to_fixed(60)}, size = Vec2{to_fixed(4), to_fixed(16)}, color = named_color(.White)}}}
	rect_bytes := frame_bytes(empty_version, rect_list)
	rect_tag_offset := 16 + 8
	testing.expect(t, len(rect_bytes) > rect_tag_offset)
	testing.expect_value(t, rect_bytes[rect_tag_offset], u8(Cmd_Tag.Rect))
}

@(test)
test_mesh_builtin_folds_handle :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	program := d3_program()
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)
	interp := d3_interp(&program, &version, Fixed(0))

	call := d3_call("mesh", d3_string("krognid_torso"))
	value, ok := eval_in_d3(&interp, &call)
	testing.expect(t, ok)
	handle, is_record := value.(Record_Value)
	testing.expect(t, is_record)
	testing.expect_value(t, handle.type_name, "MeshHandle")
	name_field, name_present := handle.fields["name"]
	testing.expect(t, name_present)
	name_str, is_str := name_field.(String_Value)
	testing.expect(t, is_str)
	testing.expect_value(t, name_str.text, "krognid_torso")

	name_arg, arg_ok := eval_mesh_name_arg(&interp, &call, &Env{names = make(map[string]Value, context.temp_allocator)})
	testing.expect(t, arg_ok)
	testing.expect_value(t, name_arg, "krognid_torso")

	bad := d3_call("mesh", d3_fixed(to_fixed(1)))
	_, bad_ok := eval_in_d3(&interp, &bad)
	testing.expect(t, !bad_ok)
}

@(private = "file")
eval_in_d3 :: proc(interp: ^Interp, node: ^Node) -> (Value, bool) {
	env := Env{names = make(map[string]Value, context.temp_allocator)}
	return eval(interp, node, &env)
}

@(private = "file")
d3_slices_equal :: proc(a, b: []u8) -> bool {
	if len(a) != len(b) {
		return false
	}
	for v, i in a {
		if b[i] != v {
			return false
		}
	}
	return true
}
