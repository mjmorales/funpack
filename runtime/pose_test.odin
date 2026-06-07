// The §16 §7 pose/anim EVALUATION-surface proof over a HAND-BUILT node forest (the
// interp_test/trig_test idiom, no artifact): the runtime reproduces stroll.fun's
// pure fixed-point pose asserts BIT-FOR-BIT and folds draw_krognid's body to a
// Draw3::Rigged record carrying skeleton/parts/pose/at.
//
// The asserted golden values come from two funpack-side sources, replicated here
// (the runtime carries no funpack import — kernel-copy-not-link, so the values are
// reproduced through the copied pose/quat/trig kernels and pinned by the same
// expected forms):
//   - funpack/pose_eval_test.odin's twelve inline asserts: pose_walk's rest-crossing
//     leg (get == rot_x(0.0)), set/get round-trip (== up(0.3)), the undriven-bone
//     rest read (== rot_x(0.0)), blend at weight 0 (== rot_x(0.0)) / weight 1 (==
//     up(0.3)), the disjoint-bone-set blend, layer overlay-wins (== up(0.5)) and
//     base-shows-through (== rot_x(0.0)), and walk_weight's clamp (1.0 / 0.0).
//   - funpack-spec/examples/krognid/src/stroll.fun's pose_idle/pose_walk/walk_weight
//     bodies and draw_krognid's body (the full blend over a hand-built Krognid row).
//
// The proof exercises the INTERP DISPATCH PATH (eval_method_call →
// eval_pose_static / eval_pose_method / eval_handle_method, the engine-constructor
// arm for Pose.empty/blend/layer / Skeleton.humanoid / PartSet.empty), not the pose
// helpers in isolation — a hand-built node forest is run through `eval`, the same
// way trig_test runs `sin(angle)`.
package funpack_runtime

import "core:testing"

// --- node-forest builders (the trig_test idiom, heap-allocated so a forest escapes
// its constructing stack frame) ------------------------------------------------

// pose_tokens heap-allocates a node's scalar-token slice from the temp arena.
@(private = "file")
pose_tokens :: proc(tokens: ..string) -> []string {
	out := make([]string, len(tokens), context.temp_allocator)
	copy(out, tokens)
	return out
}

// pose_kids heap-allocates a node's child slice from the temp arena.
@(private = "file")
pose_kids :: proc(nodes: ..Node) -> []Node {
	out := make([]Node, len(nodes), context.temp_allocator)
	copy(out, nodes)
	return out
}

// n_name builds a `.Name` node — a local binding / const / builtin-const read.
@(private = "file")
n_name :: proc(name: string) -> Node {
	return Node{kind = .Name, fields = pose_tokens(name)}
}

// n_fixed builds a `.Fixed` literal node whose token is the raw Q32.32 bits as a
// decimal i64 (the artifact encoding decode_fixed reads), so a fractional literal
// (0.5, 0.2) is built through the kernel — no float on the path.
@(private = "file")
n_fixed :: proc(f: Fixed) -> Node {
	return Node{kind = .Fixed, fields = pose_tokens(aprint_int(i64(f), context.temp_allocator))}
}

// n_variant builds a bare (payload-less) enum-variant node — Bone::LUpperLeg,
// Slot::Torso, Side::L.
@(private = "file")
n_variant :: proc(enum_type, case_name: string) -> Node {
	return Node{kind = .Variant, fields = pose_tokens(enum_type, case_name, "false")}
}

// n_call builds a named-call node `name(args...)`: a `.Call` over a `.Name` callee
// with the arg subtrees following.
@(private = "file")
n_call :: proc(name: string, args: ..Node) -> Node {
	children := make([]Node, len(args) + 1, context.temp_allocator)
	children[0] = n_name(name)
	copy(children[1:], args)
	return Node{kind = .Call, children = children}
}

// n_method builds a method-call node `recv.method(args...)`: a `.Call` over a
// `.Field` callee (the method token + the receiver subtree) with the arg subtrees
// following — the form eval_method_call dispatches.
@(private = "file")
n_method :: proc(recv: Node, method: string, args: ..Node) -> Node {
	field := Node{kind = .Field, fields = pose_tokens(method), children = pose_kids(recv)}
	children := make([]Node, len(args) + 1, context.temp_allocator)
	children[0] = field
	copy(children[1:], args)
	return Node{kind = .Call, children = children}
}

// n_binary builds a binary-op node — `mul`/`add`/`sub`/`eq`.
@(private = "file")
n_binary :: proc(op: string, lhs, rhs: Node) -> Node {
	return Node{kind = .Binary, fields = pose_tokens(op), children = pose_kids(lhs, rhs)}
}

// n_unary builds a unary-op node — `neg` (the -s counter-swing in pose_walk).
@(private = "file")
n_unary :: proc(op: string, operand: Node) -> Node {
	return Node{kind = .Unary, fields = pose_tokens(op), children = pose_kids(operand)}
}

// n_field builds a field-read node `recv.field` (self.phase, time.t).
@(private = "file")
n_field :: proc(recv: Node, field: string) -> Node {
	return Node{kind = .Field, fields = pose_tokens(field), children = pose_kids(recv)}
}

// n_recfield builds a record-field node `name: value`.
@(private = "file")
n_recfield :: proc(name: string, value: Node) -> Node {
	return Node{kind = .Recfield, fields = pose_tokens(name), children = pose_kids(value)}
}

// n_record builds a record-literal node `Type{fields...}` — the struct-payload
// variant Draw3::Rigged lands here as a `::`-typed Record_Value.
@(private = "file")
n_record :: proc(type_name: string, fields: ..Node) -> Node {
	return Node{kind = .Record, fields = pose_tokens(type_name), children = pose_kids(..fields)}
}

// n_list builds a list-literal node `[elems...]` — draw_krognid returns a [Draw3].
@(private = "file")
n_list :: proc(elems: ..Node) -> Node {
	return Node{kind = .List, children = pose_kids(..elems)}
}

// --- pose-source helpers (mirror stroll.fun's pose_idle/pose_walk/walk_weight as
// node forests, so the asserts run the real interp dispatch path) ---------------

// rot_x(angle) node.
@(private = "file")
n_rot_x :: proc(angle: Node) -> Node {return n_call("rot_x", angle)}

// up(d) node.
@(private = "file")
n_up :: proc(d: Node) -> Node {return n_call("up", d)}

// Pose.empty() node (a static engine constructor: a `.Field` over the `Pose` type
// name with no args).
@(private = "file")
n_pose_empty :: proc() -> Node {
	return n_method(n_name("Pose"), "empty")
}

// fixed_lit converts an integer/fraction pair to a Fixed through the kernel so a
// literal is built with no float — fixed_lit(2, 10) is 0.2, fixed_lit(1, 1) is 1.0.
@(private = "file")
fixed_lit :: proc(num, den: i64) -> Fixed {
	return fixed_div(to_fixed(num), to_fixed(den))
}

// make_pose_interp builds a read-only interpreter over a hand-built program whose
// functions are the krognid pose helpers, with a Time resource carrying both `dt`
// (60hz) and `t` (the idle bob's clock the pose_idle body reads).
@(private = "file")
make_pose_interp :: proc(program: ^Program, version: ^World_Version, t: Fixed) -> Interp {
	time_fields := make(map[string]Value, context.temp_allocator)
	time_fields["dt"] = fixed_div(to_fixed(1), to_fixed(60))
	time_fields["t"] = t
	time := Record_Value{type_name = "Time", fields = time_fields}
	return new_interp(program, version, nil, empty(), time, context.temp_allocator)
}

// pose_program builds the hand-built program the pose tests fold against: the
// krognid pose helpers as Function_Decls with hand-built bodies, mirroring
// stroll.fun + krognid.gen.fun. A behavior reads these as user fns through
// program_function (the same path eval_named_call / eval_user_call take).
@(private = "file")
pose_program :: proc() -> Program {
	// walk_weight(speed) = clamp(speed * 2.0, 0.0, 1.0)
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

	// pose_idle(t) = Pose.empty().set(Bone::Torso, up(sin(t * 2.0) * 0.2))
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

	// pose_walk(phase, speed):
	//   let s = sin(phase) * 0.5
	//   Pose.empty()
	//     .set(LUpperLeg, rot_x(s)).set(RUpperLeg, rot_x(-s))
	//     .set(LUpperArm, rot_x(-s*0.6)).set(RUpperArm, rot_x(s*0.6))
	//     .set(Torso, up(sin(phase*2.0)*0.3))
	// (the torso bob omits stroll.fun's abs() wrap — the asserted bones are the
	// legs/arms, which match stroll.fun exactly; pose_eval_test.odin makes the same
	// budget-driven omission.)
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

	// krognid_skeleton() = Skeleton.humanoid()
	krognid_skeleton := Function_Decl {
		name = "krognid_skeleton",
		kind = .Fn,
		return_type = "Skeleton",
		body = pose_body(
			Node{kind = .Return, children = pose_kids(n_method(n_name("Skeleton"), "humanoid"))},
		),
	}

	// krognid_parts() = PartSet.empty().bind(Slot::Torso, mesh("krognid_torso")).…
	//   .bind(Slot::Head, mesh("krognid_head"))…
	//   .mirror(Side::L, Side::R)
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

	// draw_krognid's body (the render behavior step), as a user fn over (self, time)
	// so the test calls it through the user-fn path:
	//   let pose = Pose.blend(pose_idle(time.t), pose_walk(self.phase, self.speed), walk_weight(self.speed))
	//   [Draw3::Rigged{ skeleton: krognid_skeleton(), parts: krognid_parts(), pose: pose, at: self.pos }]
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

// n_string builds a `.String` literal node — a mesh handle's asset name. The
// runtime String node decodes a length-prefixed `L<len>:<bytes>` token (§2.4), so
// the builder frames the bytes the same way the artifact emitter does.
@(private = "file")
n_string :: proc(text: string) -> Node {
	token := aprint_concat("L", aprint_int(i64(len(text)), context.temp_allocator), ":", text)
	return Node{kind = .String, fields = pose_tokens(token)}
}

// aprint_concat joins string parts in the temp arena — the §2.4 length-prefixed
// String token a hand-built node carries.
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

// n_mesh builds a `MeshHandle{name: "<asset>"}` record literal — the value
// funpack's mesh("<asset>") asset constructor produces (a typed handle carrying the
// one `name` field). The runtime has no `mesh` builtin (the asset-constructor
// surface is a separate story), so the parts builder feeds the handle record
// directly; eval_mesh_name_arg reads its `name` field, the same value the
// constructor would have built.
@(private = "file")
n_mesh :: proc(asset: string) -> Node {
	return n_record("MeshHandle", n_recfield("name", n_string(asset)))
}

// pose_param_slice heap-allocates a Param_Decl slice from {name, type} pairs.
@(private = "file")
pose_param_slice :: proc(pairs: ..[2]string) -> []Param_Decl {
	out := make([]Param_Decl, len(pairs), context.temp_allocator)
	for pair, i in pairs {
		out[i] = Param_Decl{name = pair[0], type = pair[1]}
	}
	return out
}

// pose_body heap-allocates a statement-node body slice.
@(private = "file")
pose_body :: proc(stmts: ..Node) -> []Node {
	out := make([]Node, len(stmts), context.temp_allocator)
	copy(out, stmts)
	return out
}

// pose_version builds the empty initial version over the hand-built pose program —
// the committed snapshot a read falls back to (the pose asserts consult no rows, so
// the empty version suffices). The caller keeps it as a LOCAL and passes `&version`
// to make_pose_interp, so the interp's version pointer never dangles (the
// trig_test/interp_test setup discipline).
@(private = "file")
pose_version :: proc(program: ^Program) -> World_Version {
	return initial_version(new_world(program^, context.temp_allocator), context.temp_allocator)
}

// eval_in evaluates a hand-built node against a fresh scope seeded with the given
// (name, value) bindings — the calling frame a body expression reads against.
@(private = "file")
eval_in :: proc(interp: ^Interp, node: ^Node, bindings: ..struct{name: string, value: Value}) -> (Value, bool) {
	env := Env{names = make(map[string]Value, context.temp_allocator)}
	for b in bindings {
		env.names[b.name] = b.value
	}
	return eval(interp, node, &env)
}

// test_pose_builders_eval replicates the funpack-evaluable pose asserts that pin the
// transform builders and the sparse-pose set/get surface — pose_walk's rest-crossing
// leg (get == rot_x(0.0)), the set/get round-trip (== up(0.3)), the undriven-bone
// rest read (== rot_x(0.0)), and walk_weight's clamp at both ends — folded through
// the interp dispatch path over the hand-built krognid pose program. Bit-for-bit
// with stroll.fun / pose_eval_test.odin (the runtime reproduces the funpack golden
// values through the copied pose/quat/trig kernels).
@(test)
test_pose_builders_eval :: proc(t: ^testing.T) {
	program := pose_program()
	version := pose_version(&program)
	interp := make_pose_interp(&program, &version, Fixed(0))

	// pose_walk(0.0, 1.0).get(Bone::LUpperLeg) == rot_x(0.0) — at phase 0, sin(0)=0
	// so s=0 and rot_x(0) is the rest transform (the §16 §7 zero-crossing anchor).
	walk0 := n_method(
		n_call("pose_walk", n_fixed(Fixed(0)), n_fixed(FIXED_ONE)),
		"get",
		n_variant("Bone", "LUpperLeg"),
	)
	leg, leg_ok := eval_in(&interp, &walk0)
	testing.expect(t, leg_ok)
	testing.expect(t, values_equal(leg, transform_rot_x(Fixed(0))))
	// rot_x(0.0) IS the rest transform — the undriven-bone default.
	testing.expect(t, values_equal(leg, transform_identity()))

	// Pose.empty().set(Bone::Torso, up(0.3)).get(Bone::Torso) == up(0.3) — a .set
	// then .get round-trips one driven bone's transform exactly.
	set_get := n_method(
		n_method(n_pose_empty(), "set", n_variant("Bone", "Torso"), n_up(n_fixed(fixed_lit(3, 10)))),
		"get",
		n_variant("Bone", "Torso"),
	)
	torso, torso_ok := eval_in(&interp, &set_get)
	testing.expect(t, torso_ok)
	testing.expect(t, values_equal(torso, transform_up(fixed_lit(3, 10))))

	// A bone the pose never drives reads the rest transform (== rot_x(0.0)).
	undriven := n_method(
		n_method(n_pose_empty(), "set", n_variant("Bone", "Torso"), n_up(n_fixed(fixed_lit(3, 10)))),
		"get",
		n_variant("Bone", "Head"),
	)
	head, head_ok := eval_in(&interp, &undriven)
	testing.expect(t, head_ok)
	testing.expect(t, values_equal(head, transform_rot_x(Fixed(0))))

	// walk_weight(1.0) == 1.0 (clamps to the top) and walk_weight(0.0) == 0.0.
	ww_full := n_call("walk_weight", n_fixed(FIXED_ONE))
	full, full_ok := eval_in(&interp, &ww_full)
	testing.expect(t, full_ok)
	testing.expect_value(t, full.(Fixed), FIXED_ONE)

	ww_rest := n_call("walk_weight", n_fixed(Fixed(0)))
	rest, rest_ok := eval_in(&interp, &ww_rest)
	testing.expect(t, rest_ok)
	testing.expect_value(t, rest.(Fixed), Fixed(0))

	// Error case: Pose.get on an unset bone reads rest (total, never a fault) — and
	// a .set of a NON-Bone arg is fail-closed (ok=false), the §16 §7 surface refuses
	// a non-variant key rather than coercing it.
	bad_set := n_method(n_pose_empty(), "set", n_fixed(Fixed(0)), n_up(n_fixed(Fixed(0))))
	_, bad_ok := eval_in(&interp, &bad_set)
	testing.expect(t, !bad_ok)
}

// test_pose_blend_and_layer replicates the funpack-evaluable blend/layer per-bone
// asserts: blend at weight 0 takes the base pose's driven bone (== rot_x(0.0)),
// blend at weight 1 takes the overlaid pose's bone (== up(0.3)), a disjoint-bone-set
// blend keeps every bone, layer overlay-wins on a shared bone (== up(0.5)), and
// layer shows the base through on a bone the overlay does not drive (== rot_x(0.0)).
// Bit-for-bit with pose_eval_test.odin, through the interp dispatch path.
@(test)
test_pose_blend_and_layer :: proc(t: ^testing.T) {
	program := pose_program()
	version := pose_version(&program)
	interp := make_pose_interp(&program, &version, Fixed(0))

	// Pose.blend(pose_walk(0.0,1.0), pose_idle(0.0), 0.0).get(Bone::LUpperLeg) ==
	// rot_x(0.0) — at weight 0 the leg reads the base pose's driven value (the slerp
	// endpoint identity), which at phase 0 is rest.
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

	// Pose.blend(Pose.empty(), Pose.empty().set(Torso, up(0.3)), 1.0).get(Torso) ==
	// up(0.3) — at weight 1 the torso reads the overlaid pose's driven value.
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

	// Pose.blend(Pose.empty().set(LUpperLeg, rot_x(0.0)), Pose.empty().set(Torso,
	// up(0.5)), 0.0).get(LUpperLeg) == rot_x(0.0) — a blend of disjoint bone sets
	// keeps every bone; at weight 0 the leg reads its base-driven rest.
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

	// Pose.layer(Pose.empty().set(Torso, up(0.1)), Pose.empty().set(Torso, up(0.5)))
	//   .get(Torso) == up(0.5) — the overlay wins per bone.
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

	// Pose.layer(Pose.empty().set(LUpperLeg, rot_x(0.0)), Pose.empty().set(Torso,
	// up(0.5))).get(LUpperLeg) == rot_x(0.0) — the base shows through on a bone the
	// overlay does not drive.
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

	// Error case: Pose.blend with a weight out of [0,1] is NOT clamped by blend
	// itself (the clamp is walk_weight's job at the call site); blend honors the raw
	// weight, and the slerp/lerp endpoints are identity only AT 0/1, so an
	// out-of-range weight still evaluates (total) — proving blend never faults on a
	// weight the caller failed to clamp. Here weight 2.0 over rot_x(0.0)→rot_x(0.0)
	// is still the identity (both endpoints rest), so it reads rest, not a fault.
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

// test_draw_krognid_folds_to_rigged evaluates draw_krognid's body over a HAND-BUILT
// Krognid row — blend(pose_idle(time.t), pose_walk(self.phase, self.speed),
// walk_weight(self.speed)) folded into a [Draw3] carrying one Draw3::Rigged record —
// and asserts the Rigged record carries skeleton/parts/pose/at:
//   - skeleton: the opaque Skeleton.humanoid() handle
//   - parts: the opaque PartSet built through the six binds + the L→R mirror
//   - pose: the blended Pose (a Pose_Value), driving the union of the idle/walk bones
//   - at: the creature's world position (the Vec3 self.pos)
// This is the end-to-end pose-evaluation fold the §16 §7 render surface rests on:
// the cross-fn body (draw_krognid calls pose_idle/pose_walk/walk_weight/
// krognid_skeleton/krognid_parts) resolves every name through program_function and
// folds to the Rigged record.
@(test)
test_draw_krognid_folds_to_rigged :: proc(t: ^testing.T) {
	program := pose_program()
	// A walking creature: a non-zero phase and speed, so the blend is a real
	// idle/walk mix (walk_weight(0.5) ramps the walk pose in) over a Vec3 position.
	version := pose_version(&program)
	interp := make_pose_interp(&program, &version, Fixed(0))

	self_fields := make(map[string]Value, context.temp_allocator)
	self_fields["player"] = Variant_Value{enum_type = "PlayerId", case_name = "P1"}
	self_fields["pos"] = Vec3{x = to_fixed(25), y = Fixed(0), z = to_fixed(25)}
	self_fields["intent"] = Vec2{x = Fixed(0), y = Fixed(0)}
	self_fields["phase"] = fixed_lit(1, 2) // 0.5 rad into the walk cycle
	self_fields["speed"] = fixed_lit(1, 2) // 0.5 ground speed
	self := Record_Value{type_name = "Krognid", fields = self_fields}

	draw := program_function(&program, "draw_krognid")
	testing.expect(t, draw != nil)

	// Call draw_krognid(self, time) through the user-fn body fold: bind self + time
	// into a fresh scope and fold the body (the same path the tick takes for a
	// render behavior step).
	scope := Env{names = make(map[string]Value, context.temp_allocator)}
	scope.names["self"] = self
	scope.names["time"] = interp.time
	draws, draws_ok := eval_body(&interp, draw.body, &scope)
	testing.expect(t, draws_ok)

	// The body returns a [Draw3] with exactly one element — the Rigged draw.
	list, is_list := draws.(List_Value)
	testing.expect(t, is_list)
	testing.expect_value(t, len(list.elements), 1)
	if len(list.elements) != 1 {
		return
	}

	rigged, is_rigged := list.elements[0].(Record_Value)
	testing.expect(t, is_rigged)
	testing.expect_value(t, rigged.type_name, "Draw3::Rigged")

	// at: the world position (the Vec3 self.pos) rides through verbatim.
	at, at_present := rigged.fields["at"]
	testing.expect(t, at_present)
	testing.expect(t, values_equal(at, Vec3{x = to_fixed(25), y = Fixed(0), z = to_fixed(25)}))

	// skeleton: the opaque Skeleton.humanoid() handle.
	skeleton, sk_present := rigged.fields["skeleton"]
	testing.expect(t, sk_present)
	sk_handle, sk_is_handle := skeleton.(Handle_Value)
	testing.expect(t, sk_is_handle)
	testing.expect_value(t, sk_handle.kind, "Skeleton")
	testing.expect_value(t, sk_handle.factory, "humanoid")
	testing.expect_value(t, len(sk_handle.ops), 0)
	// Equal to a freshly-built Skeleton.humanoid() handle (the §03 Eq the Rigged
	// record folds through).
	testing.expect(t, values_equal(skeleton, Handle_Value{kind = "Skeleton", factory = "humanoid", ops = make([]Handle_Op, 0, context.temp_allocator)}))

	// parts: the opaque PartSet handle with the six binds + the L→R mirror, in order.
	parts, pt_present := rigged.fields["parts"]
	testing.expect(t, pt_present)
	pt_handle, pt_is_handle := parts.(Handle_Value)
	testing.expect(t, pt_is_handle)
	testing.expect_value(t, pt_handle.kind, "PartSet")
	testing.expect_value(t, pt_handle.factory, "empty")
	testing.expect_value(t, len(pt_handle.ops), 7) // 6 binds + 1 mirror
	if len(pt_handle.ops) == 7 {
		testing.expect_value(t, pt_handle.ops[0].method, "bind")
		testing.expect_value(t, pt_handle.ops[0].args[0], "Torso")
		testing.expect_value(t, pt_handle.ops[0].args[1], "krognid_torso")
		testing.expect_value(t, pt_handle.ops[6].method, "mirror")
		testing.expect_value(t, pt_handle.ops[6].args[0], "L")
		testing.expect_value(t, pt_handle.ops[6].args[1], "R")
	}

	// pose: the blended Pose (a Pose_Value). The blend drives the UNION of the idle
	// pose's bones (Torso) and the walk pose's bones (LUpperLeg/RUpperLeg/LUpperArm/
	// RUpperArm/Torso) — five distinct bones.
	pose, pose_present := rigged.fields["pose"]
	testing.expect(t, pose_present)
	pose_value, pose_is := pose.(Pose_Value)
	testing.expect(t, pose_is)
	testing.expect_value(t, len(pose_value.bones), 5)
	// The pose drives the five rig bones the idle/walk union covers.
	for bone in ([]string{"Torso", "LUpperLeg", "RUpperLeg", "LUpperArm", "RUpperArm"}) {
		_, found := pose_bone_transform(pose_value.bones, bone)
		testing.expectf(t, found, "blended pose drives bone %s", bone)
	}

	// The blended pose equals a directly-computed blend(pose_idle(0), pose_walk(0.5,
	// 0.5), walk_weight(0.5)) — the body fold IS the pose math, bit-for-bit (the
	// determinism floor: the same blend through the body and through the helpers).
	idle_call := n_call("pose_idle", n_fixed(Fixed(0)))
	walk_call := n_call("pose_walk", n_fixed(fixed_lit(1, 2)), n_fixed(fixed_lit(1, 2)))
	ww_call := n_call("walk_weight", n_fixed(fixed_lit(1, 2)))
	idle, idle_ok := eval_in(&interp, &idle_call)
	walk, walk_ok := eval_in(&interp, &walk_call)
	ww, ww_ok := eval_in(&interp, &ww_call)
	testing.expect(t, idle_ok && walk_ok && ww_ok)
	// The body is blend(pose_idle, pose_walk, walk_weight) — idle is the base (a),
	// walk the overlay (b); the blend is per-bone and NOT symmetric, so the argument
	// order matches the body exactly.
	expected_pose := eval_pose_blend(&interp, idle.(Pose_Value), walk.(Pose_Value), ww.(Fixed))
	testing.expect(t, values_equal(pose, expected_pose))
}
