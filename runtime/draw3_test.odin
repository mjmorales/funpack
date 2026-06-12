// The §20 §1 Draw3 lowering + frame-digest fold proof over HAND-BUILT fixtures (the
// pose_test/interp_test idiom — node-forest bodies, no artifact). It proves the four
// load-bearing properties this task rests on:
//
//   - LOWERING: a hand-built committed Krognid+Field world's draw_scene/draw_krognid
//     bodies fold to a STABLE Draw3 draw-list — draw_scene to the
//     Camera/Light/Plane triple, draw_krognid to one Rigged record carrying the §16 §7
//     rig (skeleton/parts/pose/at). Every Vec3/fov/extent reads its exact value
//     through the lowering (render.odin draw_command_from_record);
//   - DIGEST DETERMINISM: two independent folds of the SAME committed draw-list digest
//     byte-identically (the frame digest is a pure content hash over the full 3D
//     state), and a single differing Fixed bit (a moved creature, a recolored plane)
//     changes the digest — the 3D commands are inside the comparison surface;
//   - 2D GOLDEN STABILITY (asserted in full by the committed-golden replay tests):
//     the v6 Cmd_Tag append leaves a 2D-only draw-list's bytes unmoved — proven here by
//     a Rect-only draw-list digesting the SAME at v6 as its raw-byte expectation, and
//     by the appended ordinals taking 3..6 while Rect/Text/Camera keep 0..2.
//
// The bodies are folded through the user-fn path (the same eval_body draw_krognid's
// render behavior step takes), then lowered via append_draw_commands (exactly what
// render_behavior_over_instances calls per instance) — so the test exercises the real
// lowering flow, not the readers in isolation.
package funpack_runtime

import "core:testing"

// --- node-forest builders (file-private; mirror the pose_test idiom) -----------

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

// d3_name builds a `.Name` node — a local/const/builtin read.
@(private = "file")
d3_name :: proc(name: string) -> Node {
	return Node{kind = .Name, fields = d3_tokens(name)}
}

// d3_fixed builds a `.Fixed` literal node whose token is the raw Q32.32 bits as a
// decimal i64 (the artifact encoding decode_fixed reads) — no float on the path.
@(private = "file")
d3_fixed :: proc(f: Fixed) -> Node {
	return Node{kind = .Fixed, fields = d3_tokens(aprint_int(i64(f), context.temp_allocator))}
}

// d3_variant builds a bare (payload-less) enum-variant node — Color::White,
// Bone::Torso, Slot::Torso, Side::L.
@(private = "file")
d3_variant :: proc(enum_type, case_name: string) -> Node {
	return Node{kind = .Variant, fields = d3_tokens(enum_type, case_name, "false")}
}

// d3_recfield builds a `name: value` record field node.
@(private = "file")
d3_recfield :: proc(name: string, value: Node) -> Node {
	return Node{kind = .Recfield, fields = d3_tokens(name), children = d3_kids(value)}
}

// d3_record builds a `Type{fields...}` record-literal node — a Draw3::* struct-payload
// variant lands here as a `::`-typed Record_Value the lowering keys off type_name.
@(private = "file")
d3_record :: proc(type_name: string, fields: ..Node) -> Node {
	return Node{kind = .Record, fields = d3_tokens(type_name), children = d3_kids(..fields)}
}

// d3_list builds a `[elems...]` list-literal node — a [Draw3] return.
@(private = "file")
d3_list :: proc(elems: ..Node) -> Node {
	return Node{kind = .List, children = d3_kids(..elems)}
}

// d3_field builds a `recv.field` read (self.pos).
@(private = "file")
d3_field :: proc(recv: Node, field: string) -> Node {
	return Node{kind = .Field, fields = d3_tokens(field), children = d3_kids(recv)}
}

// d3_vec3 builds a `Vec3{x:_, y:_, z:_}` record literal — collapses to a Vec3 value
// through eval_record's Vec3 arm (interp.odin), the determinism-path 3D position.
@(private = "file")
d3_vec3 :: proc(x, y, z: Fixed) -> Node {
	return d3_record(
		"Vec3",
		d3_recfield("x", d3_fixed(x)),
		d3_recfield("y", d3_fixed(y)),
		d3_recfield("z", d3_fixed(z)),
	)
}

// d3_vec2 builds a `Vec2{x:_, y:_}` record literal — collapses to a Vec2 value.
@(private = "file")
d3_vec2 :: proc(x, y: Fixed) -> Node {
	return d3_record("Vec2", d3_recfield("x", d3_fixed(x)), d3_recfield("y", d3_fixed(y)))
}

// d3_program builds a hand-built program whose user fns are draw_scene's and
// draw_krognid's bodies (and the krognid pose helpers draw_krognid calls). A render
// behavior step folds through eval_body the same way these user fns do, so calling
// them through the body fold exercises the real evaluation + lowering path.
@(private = "file")
d3_program :: proc() -> Program {
	// draw_scene(self) -> [Draw3] = [
	//   Draw3::Camera{ eye: Vec3{25,40,-30}, at: Vec3{25,0,25}, fov: 60.0 },
	//   Draw3::Light{ dir: Vec3{-0.3,-1.0,-0.2}, color: Color::White },
	//   Draw3::Plane{ at: Vec3{25,0,25}, size: Vec2{50,50}, color: Color::Gray },
	// ]
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

	// draw_krognid(self, time) -> [Draw3]:
	//   let pose = Pose.blend(pose_idle(time.t), pose_walk(self.phase, self.speed), walk_weight(self.speed))
	//   [Draw3::Rigged{ skeleton: krognid_skeleton(), parts: krognid_parts(), pose: pose, at: self.pos }]
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

// d3_pose_helpers builds the krognid pose-source fns draw_krognid calls
// (walk_weight / pose_idle / pose_walk / krognid_skeleton / krognid_parts) — the
// same node-forest helpers pose_test pins, replicated here so this file is
// self-contained (file-private builders cannot cross files).
@(private = "file")
d3_pose_helpers :: proc() -> []Function_Decl {
	// walk_weight(speed) = clamp(speed * 2.0, 0.0, 1.0)
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

	// pose_idle(t) = Pose.empty().set(Bone::Torso, up(sin(t * 2.0) * 0.2))
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

	// pose_walk(phase, speed):
	//   let s = sin(phase) * 0.5
	//   Pose.empty().set(LUpperLeg, rot_x(s)).set(RUpperLeg, rot_x(-s))
	//     .set(LUpperArm, rot_x(-s*0.6)).set(RUpperArm, rot_x(s*0.6))
	//     .set(Torso, up(sin(phase*2.0)*0.3))
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

	// krognid_skeleton() = Skeleton.humanoid()
	krognid_skeleton := Function_Decl {
		name        = "krognid_skeleton",
		kind        = .Fn,
		return_type = "Skeleton",
		body        = d3_body(
			Node{kind = .Return, children = d3_kids(d3_method(d3_name("Skeleton"), "humanoid"))},
		),
	}

	// krognid_parts() = PartSet.empty().bind(Slot::Torso, mesh("krognid_torso")).mirror(Side::L, Side::R)
	// (the bind uses the WIRED mesh() builtin this task added — not a hand-built handle
	// record — so the artifact-path constructor is exercised end to end.)
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

// d3_call builds `name(args...)`.
@(private = "file")
d3_call :: proc(name: string, args: ..Node) -> Node {
	children := make([]Node, len(args) + 1, context.temp_allocator)
	children[0] = d3_name(name)
	copy(children[1:], args)
	return Node{kind = .Call, children = children}
}

// d3_method builds `recv.method(args...)`.
@(private = "file")
d3_method :: proc(recv: Node, method: string, args: ..Node) -> Node {
	field := Node{kind = .Field, fields = d3_tokens(method), children = d3_kids(recv)}
	children := make([]Node, len(args) + 1, context.temp_allocator)
	children[0] = field
	copy(children[1:], args)
	return Node{kind = .Call, children = children}
}

// d3_binary / d3_unary build arithmetic op nodes.
@(private = "file")
d3_binary :: proc(op: string, lhs, rhs: Node) -> Node {
	return Node{kind = .Binary, fields = d3_tokens(op), children = d3_kids(lhs, rhs)}
}

@(private = "file")
d3_unary :: proc(op: string, operand: Node) -> Node {
	return Node{kind = .Unary, fields = d3_tokens(op), children = d3_kids(operand)}
}

// d3_pose_empty builds Pose.empty().
@(private = "file")
d3_pose_empty :: proc() -> Node {
	return d3_method(d3_name("Pose"), "empty")
}

// d3_string builds a `.String` literal node (a mesh asset name) — the §2.4
// length-prefixed `L<len>:<bytes>` token decode_string reads.
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

// d3_frac converts num/den to a Fixed through the kernel — no float on the path.
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

// d3_interp builds a read-only interpreter over the hand-built program with a Time
// resource carrying dt (60hz) and t (the idle clock).
@(private = "file")
d3_interp :: proc(program: ^Program, version: ^World_Version, t: Fixed) -> Interp {
	time_fields := make(map[string]Value, context.temp_allocator)
	time_fields["dt"] = fixed_div(to_fixed(1), to_fixed(60))
	time_fields["t"] = t
	time := Record_Value{type_name = "Time", fields = time_fields}
	return new_interp(program, version, nil, empty(), time, context.temp_allocator)
}

// d3_krognid_self builds a hand-built Krognid `self` blackboard at a given world
// position — the committed instance draw_krognid folds over.
@(private = "file")
d3_krognid_self :: proc(pos: Vec3) -> Record_Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["player"] = Variant_Value{enum_type = "PlayerId", case_name = "P1"}
	fields["pos"] = pos
	fields["intent"] = Vec2{x = Fixed(0), y = Fixed(0)}
	fields["phase"] = fixed_div(to_fixed(1), to_fixed(2)) // 0.5 rad into the cycle
	fields["speed"] = fixed_div(to_fixed(1), to_fixed(2)) // 0.5 ground speed
	return Record_Value{type_name = "Krognid", fields = fields}
}

// d3_fold_scene folds the hand-built committed Krognid+Field world to its draw-list:
// draw_scene over the Field singleton, then draw_krognid over the Krognid instance —
// the flattened render order draw_scene-then-draw_krognid (stroll.fun's render slot).
// Each body folds through eval_body and lowers through append_draw_commands, the same
// path render_behavior_over_instances takes per instance.
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
	// A hand-built committed Krognid+Field world folds to a STABLE Draw3 draw-list:
	// draw_scene lowers to the Camera/Light/Plane triple (every Vec3/fov/extent read
	// exactly through the lowering), draw_krognid lowers to one Rigged record carrying
	// the §16 §7 rig. This is the §20 §1 3D-command lowering the digest and present
	// both consume.
	context.allocator = context.temp_allocator

	program := d3_program()
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)
	interp := d3_interp(&program, &version, Fixed(0))

	self := d3_krognid_self(Vec3{x = to_fixed(25), y = Fixed(0), z = to_fixed(25)})
	draw := d3_fold_scene(&interp, &program, self)

	// Four commands: Camera, Light, Plane (draw_scene), then Rigged (draw_krognid).
	if !testing.expect_value(t, len(draw.cmds), 4) {
		return
	}

	// [0] Draw3_Camera: eye/at Vec3s + fov read verbatim.
	cam, cam_is := draw.cmds[0].(Draw3_Camera)
	testing.expect(t, cam_is)
	testing.expect(t, cam.eye == Vec3{x = to_fixed(25), y = to_fixed(40), z = fixed_neg(to_fixed(30))})
	testing.expect(t, cam.at == Vec3{x = to_fixed(25), y = Fixed(0), z = to_fixed(25)})
	testing.expect_value(t, cam.fov, to_fixed(60))

	// [1] Draw3_Light: dir Vec3 + Color::White → .White ordinal.
	light, light_is := draw.cmds[1].(Draw3_Light)
	testing.expect(t, light_is)
	testing.expect(t, light.dir == Vec3{x = fixed_neg(d3_frac(3, 10)), y = fixed_neg(to_fixed(1)), z = fixed_neg(d3_frac(2, 10))})
	testing.expect_value(t, light.color, Draw_Color.White)

	// [2] Draw3_Plane: at Vec3 + size Vec2 + Color::Gray → .Gray ordinal.
	plane, plane_is := draw.cmds[2].(Draw3_Plane)
	testing.expect(t, plane_is)
	testing.expect(t, plane.at == Vec3{x = to_fixed(25), y = Fixed(0), z = to_fixed(25)})
	testing.expect(t, plane.size == Vec2{x = to_fixed(50), y = to_fixed(50)})
	testing.expect_value(t, plane.color, Draw_Color.Gray)

	// [3] Draw3_Rigged: the §16 §7 rig — opaque handles, the blended pose, the world
	// position. The skeleton is humanoid(); the parts carry the wired mesh() bind + the
	// L→R mirror; the pose drives the idle/walk union; `at` is self.pos verbatim.
	rigged, rigged_is := draw.cmds[3].(Draw3_Rigged)
	testing.expect(t, rigged_is)
	testing.expect(t, rigged.at == Vec3{x = to_fixed(25), y = Fixed(0), z = to_fixed(25)})
	testing.expect_value(t, rigged.skeleton.kind, "Skeleton")
	testing.expect_value(t, rigged.skeleton.factory, "humanoid")
	testing.expect_value(t, rigged.parts.kind, "PartSet")
	// The mesh() builtin produced the bind arg: op[0] binds Slot::Torso to the mesh
	// asset name (the wired constructor's `name` field), op[1] mirrors L→R.
	testing.expect_value(t, len(rigged.parts.ops), 2)
	if len(rigged.parts.ops) == 2 {
		testing.expect_value(t, rigged.parts.ops[0].method, "bind")
		testing.expect_value(t, rigged.parts.ops[0].args[0], "Torso")
		testing.expect_value(t, rigged.parts.ops[0].args[1], "krognid_torso")
		testing.expect_value(t, rigged.parts.ops[1].method, "mirror")
	}
	// The pose drives the five idle/walk-union bones.
	testing.expect_value(t, len(rigged.pose.bones), 5)

	// The lowering is STABLE: a second fold of the same world produces an
	// command-identical draw-list (draw_cmd_equal folds through the rig structurally).
	again := d3_fold_scene(&interp, &program, self)
	if testing.expect_value(t, len(again.cmds), len(draw.cmds)) {
		for cmd, i in draw.cmds {
			testing.expect(t, draw_cmd_equal(cmd, again.cmds[i]))
		}
	}
}

@(test)
test_draw3_digest_deterministic :: proc(t: ^testing.T) {
	// Two independent folds of the SAME committed Draw3 draw-list digest
	// byte-identically (the frame digest is a pure content hash over the full 3D
	// state — handles, per-bone pose transforms, Vec3 positions), and a single
	// differing Fixed bit (a moved creature) changes the digest, so the 3D commands
	// are inside the comparison surface and never collapse two divergent rigs to one
	// digest. The empty world isolates the draw-list fold.
	context.allocator = context.temp_allocator

	program := d3_program()
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)
	interp := d3_interp(&program, &version, Fixed(0))

	at := Vec3{x = to_fixed(25), y = Fixed(0), z = to_fixed(25)}
	moved := Vec3{x = to_fixed(26), y = Fixed(0), z = to_fixed(25)} // one world unit over

	empty_version := World_Version{tick = 0, tables = nil}

	list_a := d3_fold_scene(&interp, &program, d3_krognid_self(at))
	list_b := d3_fold_scene(&interp, &program, d3_krognid_self(at))
	list_moved := d3_fold_scene(&interp, &program, d3_krognid_self(moved))

	// Two folds of the SAME draw-list digest identically (per-tick and over the bytes).
	digest_a := frame_digest(empty_version, list_a).digest
	digest_b := frame_digest(empty_version, list_b).digest
	testing.expect_value(t, digest_b, digest_a)

	// The same bytes twice — the canonical encoding is byte-stable.
	bytes_a := frame_bytes(empty_version, list_a)
	bytes_b := frame_bytes(empty_version, list_b)
	testing.expect(t, d3_slices_equal(bytes_a, bytes_b))

	// A moved creature changes the Rigged `at` Vec3, so its digest diverges — the 3D
	// position is folded, not dropped.
	digest_moved := frame_digest(empty_version, list_moved).digest
	testing.expect(t, digest_moved != digest_a)

	// A recolored plane (Gray → White) likewise diverges: the plane's color ordinal is
	// in the fold. Build a Draw3_Plane-only list two ways to isolate the color byte.
	plane_gray := Draw_List{cmds = []Draw_Cmd{Draw3_Plane{at = at, size = Vec2{to_fixed(50), to_fixed(50)}, color = .Gray}}}
	plane_white := Draw_List{cmds = []Draw_Cmd{Draw3_Plane{at = at, size = Vec2{to_fixed(50), to_fixed(50)}, color = .White}}}
	testing.expect(t, frame_digest(empty_version, plane_gray).digest != frame_digest(empty_version, plane_white).digest)

	// The appended Cmd_Tag ordinals: the 2D tags keep 0..2, the 3D tags take 3..6 — the
	// append discipline that leaves an existing 2D draw-list's bytes unmoved under v6.
	testing.expect_value(t, u8(Cmd_Tag.Rect), 0)
	testing.expect_value(t, u8(Cmd_Tag.Text), 1)
	testing.expect_value(t, u8(Cmd_Tag.Camera), 2)
	testing.expect_value(t, u8(Cmd_Tag.Draw3_Camera), 3)
	testing.expect_value(t, u8(Cmd_Tag.Draw3_Light), 4)
	testing.expect_value(t, u8(Cmd_Tag.Draw3_Plane), 5)
	testing.expect_value(t, u8(Cmd_Tag.Draw3_Rigged), 6)
	// And the schema version advanced deliberately — v6 appended these 3D tags;
	// v7 appended the §18 §3 batched Tilemap tag after them (tilemap_test.odin
	// pins its ordinal); v8 appended the §18 §1 entity Sprite tag after that
	// (test_draw_sprite_lowering_and_digest pins its ordinal), leaving every
	// 2D/3D/Tilemap ordinal here unmoved.
	testing.expect_value(t, FRAME_DIGEST_SCHEMA_VERSION, 8)

	// A 2D-only Rect draw-list still digests through the unchanged Rect=0 tag — a
	// proxy for the committed 2D goldens staying byte-unmoved (the committed-replay tests assert the
	// real goldens). The Rect bytes contain the Rect tag (0) and no 3D tag.
	rect_list := Draw_List{cmds = []Draw_Cmd{Draw_Rect{at = Vec2{to_fixed(8), to_fixed(60)}, size = Vec2{to_fixed(4), to_fixed(16)}, color = .White}}}
	rect_bytes := frame_bytes(empty_version, rect_list)
	// The draw-cmd tag byte is Rect=0, never a 3D ordinal — an existing 2D stream is
	// unmoved by the append. The byte sits after the empty world state (tick u64 +
	// table-count u64 = 16) and the draw-list command count (u64 = 8): offset 24.
	rect_tag_offset := 16 + 8
	testing.expect(t, len(rect_bytes) > rect_tag_offset)
	testing.expect_value(t, rect_bytes[rect_tag_offset], u8(Cmd_Tag.Rect))
}

@(test)
test_mesh_builtin_folds_handle :: proc(t: ^testing.T) {
	// The wired mesh() asset constructor (interp_call.odin builtin_mesh) folds a
	// String asset name into the typed MeshHandle record — a Record_Value tagged
	// "MeshHandle" with one `name` String field — the identical shape a MeshHandle{name:
	// "…"} literal builds and eval_mesh_name_arg (pose.odin) reads in a PartSet bind.
	// Without it the artifact-path Rigged fold fail-closes when krognid_parts() calls
	// mesh(...). A non-String arg, or the wrong arity, is fail-closed (ok=false).
	context.allocator = context.temp_allocator

	program := d3_program()
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)
	interp := d3_interp(&program, &version, Fixed(0))

	// mesh("krognid_torso") → MeshHandle{ name: "krognid_torso" }.
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

	// eval_mesh_name_arg reads the same name a PartSet.bind serializes — the value
	// the constructor builds round-trips through the bind reader.
	name_arg, arg_ok := eval_mesh_name_arg(&interp, &call, &Env{names = make(map[string]Value, context.temp_allocator)})
	testing.expect(t, arg_ok)
	testing.expect_value(t, name_arg, "krognid_torso")

	// Error case: a non-String arg (a Fixed) is fail-closed.
	bad := d3_call("mesh", d3_fixed(to_fixed(1)))
	_, bad_ok := eval_in_d3(&interp, &bad)
	testing.expect(t, !bad_ok)
}

// eval_in_d3 evaluates a hand-built node against a fresh empty scope.
@(private = "file")
eval_in_d3 :: proc(interp: ^Interp, node: ^Node) -> (Value, bool) {
	env := Env{names = make(map[string]Value, context.temp_allocator)}
	return eval(interp, node, &env)
}

// d3_slices_equal reports byte-slice length+content equality.
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
