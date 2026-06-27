package funpack_runtime

import "core:strconv"
import "core:testing"

@(private = "file")
Math_Builtin_Case :: struct {
	name: string,
	node: Node,
}

@(private = "file")
math_builtin_cases :: proc(a := context.allocator) -> []Math_Builtin_Case {
	fx :: proc(f: Fixed, a: Runtime_Allocator) -> Node {return em_fixed_node(f, a)}
	v2 :: proc(x, y: Fixed, a: Runtime_Allocator) -> Node {return em_vec2_node(x, y, a)}
	v3 :: proc(x, y, z: Fixed, a: Runtime_Allocator) -> Node {return em_vec3_node(x, y, z, a)}

	cases := make([dynamic]Math_Builtin_Case, 0, 16, a)
	append(&cases, Math_Builtin_Case{"sin", em_call_node(a, "sin", fx(to_fixed(0), a))})
	append(&cases, Math_Builtin_Case{"cos", em_call_node(a, "cos", fx(to_fixed(0), a))})
	append(&cases, Math_Builtin_Case{"sqrt", em_call_node(a, "sqrt", fx(to_fixed(4), a))})
	append(&cases, Math_Builtin_Case{"abs", em_call_node(a, "abs", fx(to_fixed(-3), a))})
	append(&cases, Math_Builtin_Case{"clamp", em_call_node(a, "clamp", fx(to_fixed(5), a), fx(to_fixed(0), a), fx(to_fixed(3), a))})
	append(&cases, Math_Builtin_Case{"lerp", em_call_node(a, "lerp", fx(to_fixed(0), a), fx(to_fixed(10), a), em_half(a))})
	append(&cases, Math_Builtin_Case{"trunc", em_call_node(a, "trunc", em_half(a))})
	append(&cases, Math_Builtin_Case{"floor", em_call_node(a, "floor", em_half(a))})
	append(&cases, Math_Builtin_Case{"round", em_call_node(a, "round", em_half(a))})
	append(&cases, Math_Builtin_Case{"checked_div", em_call_node(a, "checked_div", fx(to_fixed(6), a), fx(to_fixed(2), a))})
	append(&cases, Math_Builtin_Case{"to_fixed", em_call_node(a, "to_fixed", em_int_node(3, a))})
	append(&cases, Math_Builtin_Case{"to_int", em_call_node(a, "to_int", em_half(a))})
	append(&cases, Math_Builtin_Case{"max", em_call_node(a, "max", fx(to_fixed(1), a), fx(to_fixed(2), a))})
	append(&cases, Math_Builtin_Case{"compare", em_call_node(a, "compare", fx(to_fixed(1), a), fx(to_fixed(2), a))})
	append(&cases, Math_Builtin_Case{"dot", em_call_node(a, "dot", v2(to_fixed(1), to_fixed(2), a), v2(to_fixed(3), to_fixed(4), a))})
	append(&cases, Math_Builtin_Case{"cross", em_call_node(a, "cross", v3(to_fixed(1), to_fixed(0), to_fixed(0), a), v3(to_fixed(0), to_fixed(1), to_fixed(0), a))})
	append(&cases, Math_Builtin_Case{"length", em_call_node(a, "length", v2(to_fixed(3), to_fixed(4), a))})
	append(&cases, Math_Builtin_Case{"normalize", em_call_node(a, "normalize", v2(to_fixed(3), to_fixed(4), a))})
	return cases[:]
}

@(test)
test_engine_math_builtins_all_resolve :: proc(t: ^testing.T) {
	a := context.temp_allocator
	program := new(Program, a)
	interp := Interp{program = program, allocator = a}
	cases := math_builtin_cases(a)
	for c in cases {
		node := c.node
		env := interp_empty_env()
		_, ok := eval(&interp, &node, &env)
		testing.expectf(
			t,
			ok,
			"engine.math builtin %q evaluated ok=false — a surface name unwired in the runtime interpreter silently drops the blackboard write (interp_call.odin eval_named_call)",
			c.name,
		)
	}
}

@(test)
test_max_fixed_and_int :: proc(t: ^testing.T) {
	a := context.temp_allocator
	interp := em_bare_interp(a)

	hi := em_eval_call(&interp, a, "max", em_fixed_node(em_fx(1, 20), a), em_fixed_node(to_fixed(0), a))
	got_hi, ok_hi := hi.(Fixed)
	testing.expect(t, ok_hi)
	testing.expect_value(t, got_hi, em_fx(1, 20))

	lo := em_eval_call(&interp, a, "max", em_fixed_node(fixed_neg(em_fx(1, 20)), a), em_fixed_node(to_fixed(0), a))
	got_lo, ok_lo := lo.(Fixed)
	testing.expect(t, ok_lo)
	testing.expect_value(t, got_lo, to_fixed(0))

	int_max := em_eval_call(&interp, a, "max", em_int_node(3, a), em_int_node(7, a))
	got_int, ok_int := int_max.(i64)
	testing.expect(t, ok_int)
	testing.expect_value(t, got_int, i64(7))

	tie := em_eval_call(&interp, a, "max", em_int_node(5, a), em_int_node(5, a))
	got_tie, _ := tie.(i64)
	testing.expect_value(t, got_tie, i64(5))
}

@(test)
test_compare_folds_to_ordering :: proc(t: ^testing.T) {
	a := context.temp_allocator
	interp := em_bare_interp(a)

	expect_ordering :: proc(t: ^testing.T, v: Value, want_case: string, label: string) {
		variant, is_variant := v.(Variant_Value)
		testing.expectf(t, is_variant, "%s: result is not an Ordering variant", label)
		testing.expectf(t, variant.enum_type == "Ordering", "%s: enum_type=%q, want Ordering", label, variant.enum_type)
		testing.expectf(t, variant.case_name == want_case, "%s: case=%q, want %q", label, variant.case_name, want_case)
		testing.expectf(t, variant.payload == nil, "%s: Ordering is a unit variant (nil payload)", label)
	}

	expect_ordering(t, em_eval_call(&interp, a, "compare", em_fixed_node(to_fixed(1), a), em_fixed_node(to_fixed(2), a)), "Less", "compare(1.0, 2.0)")
	expect_ordering(t, em_eval_call(&interp, a, "compare", em_fixed_node(to_fixed(2), a), em_fixed_node(to_fixed(1), a)), "Greater", "compare(2.0, 1.0)")
	expect_ordering(t, em_eval_call(&interp, a, "compare", em_fixed_node(to_fixed(1), a), em_fixed_node(to_fixed(1), a)), "Equal", "compare(1.0, 1.0)")
	expect_ordering(t, em_eval_call(&interp, a, "compare", em_fixed_node(em_fx(1, 4), a), em_fixed_node(em_fx(1, 2), a)), "Less", "compare(0.25, 0.5)")

	expect_ordering(t, em_eval_call(&interp, a, "compare", em_int_node(3, a), em_int_node(7, a)), "Less", "compare(3, 7)")
	expect_ordering(t, em_eval_call(&interp, a, "compare", em_int_node(7, a), em_int_node(3, a)), "Greater", "compare(7, 3)")
	expect_ordering(t, em_eval_call(&interp, a, "compare", em_int_node(5, a), em_int_node(5, a)), "Equal", "compare(5, 5)")
}

@(test)
test_floor_round_trunc_to_int :: proc(t: ^testing.T) {
	a := context.temp_allocator
	interp := em_bare_interp(a)

	pos := em_fx(5, 2)
	neg := fixed_neg(pos)

	expect_int(t, em_eval_call(&interp, a, "floor", em_fixed_node(pos, a)), 2, "floor(2.5)")
	expect_int(t, em_eval_call(&interp, a, "round", em_fixed_node(pos, a)), 3, "round(2.5)")
	expect_int(t, em_eval_call(&interp, a, "trunc", em_fixed_node(pos, a)), 2, "trunc(2.5)")
	expect_int(t, em_eval_call(&interp, a, "floor", em_fixed_node(neg, a)), -3, "floor(-2.5)")
	expect_int(t, em_eval_call(&interp, a, "round", em_fixed_node(neg, a)), -3, "round(-2.5)")
	expect_int(t, em_eval_call(&interp, a, "trunc", em_fixed_node(neg, a)), -2, "trunc(-2.5)")
}

@(test)
test_lerp_fixed :: proc(t: ^testing.T) {
	a := context.temp_allocator
	interp := em_bare_interp(a)
	quarter := em_fx(1, 4)

	mid := em_eval_call(&interp, a, "lerp", em_fixed_node(to_fixed(0), a), em_fixed_node(to_fixed(10), a), em_fixed_node(quarter, a))
	got, ok := mid.(Fixed)
	testing.expect(t, ok)
	testing.expect_value(t, got, em_fx(5, 2))

	zero := em_eval_call(&interp, a, "lerp", em_fixed_node(to_fixed(0), a), em_fixed_node(to_fixed(10), a), em_fixed_node(to_fixed(0), a))
	zg, _ := zero.(Fixed)
	testing.expect_value(t, zg, to_fixed(0))

	one := em_eval_call(&interp, a, "lerp", em_fixed_node(to_fixed(0), a), em_fixed_node(to_fixed(10), a), em_fixed_node(to_fixed(1), a))
	og, _ := one.(Fixed)
	testing.expect_value(t, og, to_fixed(10))
}

@(test)
test_checked_div_option :: proc(t: ^testing.T) {
	a := context.temp_allocator
	interp := em_bare_interp(a)

	some := em_eval_call(&interp, a, "checked_div", em_fixed_node(to_fixed(6), a), em_fixed_node(to_fixed(2), a))
	sv, is_variant := some.(Variant_Value)
	testing.expect(t, is_variant)
	testing.expect_value(t, sv.enum_type, "Option")
	testing.expect_value(t, sv.case_name, "Some")
	testing.expect(t, sv.payload != nil)
	if sv.payload != nil {
		q, q_ok := sv.payload^.(Fixed)
		testing.expect(t, q_ok)
		testing.expect_value(t, q, to_fixed(3))
	}

	none := em_eval_call(&interp, a, "checked_div", em_fixed_node(to_fixed(6), a), em_fixed_node(to_fixed(0), a))
	nv, n_variant := none.(Variant_Value)
	testing.expect(t, n_variant)
	testing.expect_value(t, nv.enum_type, "Option")
	testing.expect_value(t, nv.case_name, "None")
}

@(test)
test_sqrt_cos_dot_cross_normalize :: proc(t: ^testing.T) {
	a := context.temp_allocator
	interp := em_bare_interp(a)

	root := em_eval_call(&interp, a, "sqrt", em_fixed_node(to_fixed(4), a))
	rg, r_ok := root.(Fixed)
	testing.expect(t, r_ok)
	testing.expect_value(t, rg, to_fixed(2))

	cosine := em_eval_call(&interp, a, "cos", em_fixed_node(to_fixed(0), a))
	cg, c_ok := cosine.(Fixed)
	testing.expect(t, c_ok)
	testing.expect_value(t, cg, FIXED_ONE)

	d := em_eval_call(&interp, a, "dot", em_vec2_node(to_fixed(1), to_fixed(2), a), em_vec2_node(to_fixed(3), to_fixed(4), a))
	dg, d_ok := d.(Fixed)
	testing.expect(t, d_ok)
	testing.expect_value(t, dg, to_fixed(11))

	x := em_eval_call(&interp, a, "cross", em_vec3_node(to_fixed(1), to_fixed(0), to_fixed(0), a), em_vec3_node(to_fixed(0), to_fixed(1), to_fixed(0), a))
	xg, x_ok := x.(Vec3)
	testing.expect(t, x_ok)
	testing.expect_value(t, xg, Vec3{to_fixed(0), to_fixed(0), to_fixed(1)})

	unit := em_eval_call(&interp, a, "normalize", em_vec2_node(to_fixed(3), to_fixed(4), a))
	ug, u_ok := unit.(Vec2)
	testing.expect(t, u_ok)
	testing.expect_value(t, ug.x, fixed_div(to_fixed(3), to_fixed(5)))
	testing.expect_value(t, ug.y, fixed_div(to_fixed(4), to_fixed(5)))
}

@(test)
test_cooldown_decrement_commits_with_empty_command_list :: proc(t: ^testing.T) {
	a := context.temp_allocator
	program := em_cannon_program(a)

	world := new_world(program, a)
	base := initial_version(world, a)
	base = run_startup(&program, base, a)

	start_cd := em_cannon_cooldown(t, &base)
	testing.expect_value(t, start_cd, em_fx(35, 100))

	dt := em_dt_60hz()
	time := em_time(dt, a)

	next1 := step_tick(&program, base, empty(), time, a)
	cd1 := em_cannon_cooldown(t, &next1)
	testing.expect_value(t, cd1, fixed_sub(em_fx(35, 100), dt))
	testing.expectf(t, cd1 != start_cd, "cooldown FROZE at %v — the empty-list step was dropped (the bug)", start_cd)

	next2 := step_tick(&program, next1, empty(), time, a)
	cd2 := em_cannon_cooldown(t, &next2)
	testing.expect_value(t, cd2, fixed_sub(cd1, dt))
}

@(test)
test_cooldown_floor_holds_at_zero :: proc(t: ^testing.T) {
	a := context.temp_allocator
	program := em_cannon_program_with_cooldown(a, to_fixed(0))

	world := new_world(program, a)
	base := run_startup(&program, initial_version(world, a), a)
	testing.expect_value(t, em_cannon_cooldown(t, &base), to_fixed(0))

	dt := em_dt_60hz()
	next := step_tick(&program, base, empty(), em_time(dt, a), a)
	testing.expect_value(t, em_cannon_cooldown(t, &next), to_fixed(0))
}

@(private = "file")
em_cannon_program :: proc(a := context.allocator) -> Program {
	return em_cannon_program_with_cooldown(a, em_fx(35, 100))
}

@(private = "file")
em_cannon_program_with_cooldown :: proc(a: Runtime_Allocator, cooldown: Fixed) -> Program {
	things := make([]Thing_Decl, 1, a)
	cannon_fields := make([]Field_Decl, 1, a)
	cannon_fields[0] = Field_Decl{name = "cooldown", type = "Fixed", has_default = true, default_encoded = em_fixed_bits(cooldown, a)}
	things[0] = Thing_Decl{name = "Cannon", singleton = true, fields = cannon_fields}

	behaviors := make([]Behavior_Decl, 1, a)
	behaviors[0] = em_cannon_fire_behavior(a)

	pipeline := make([]Pipeline_Step, 1, a)
	pipeline[0] = Pipeline_Step{ordinal = 0, stage = "control", behavior = "cannon_fire"}

	return Program{things = things, behaviors = behaviors, pipeline = pipeline}
}

@(private = "file")
em_cannon_fire_behavior :: proc(a := context.allocator) -> Behavior_Decl {
	params := make([]Param_Decl, 2, a)
	params[0] = Param_Decl{name = "self", type = "Cannon"}
	params[1] = Param_Decl{name = "time", type = "Time"}
	emits := make([]string, 1, a)
	emits[0] = "(Cannon, [Spawn])"

	decrement := em_binary_node(
		"sub",
		em_field_node(em_name_node("self", a), "cooldown", a),
		em_field_node(em_name_node("time", a), "dt", a),
		a,
	)
	floored := em_call_node(a, "max", decrement, em_fixed_node(to_fixed(0), a))
	updated := em_with_node(em_name_node("self", a), a, em_recfield("cooldown", floored))

	body := make([]Node, 1, a)
	body[0] = em_return_node(em_tuple_node(a, updated, em_empty_list_node(a)), a)
	return Behavior_Decl{name = "cannon_fire", on_thing = "Cannon", stage = "control", params = params, emits = emits, body = body}
}

@(private = "file")
em_cannon_cooldown :: proc(t: ^testing.T, version: ^World_Version) -> Fixed {
	row, ok := singleton_row(version, "Cannon")
	testing.expect(t, ok)
	cd, present := row_field(row, "cooldown")
	testing.expect(t, present)
	f, is_fixed := cd.(Fixed)
	testing.expect(t, is_fixed)
	return f
}

@(private = "file")
em_fx :: proc(num, den: i64) -> Fixed {
	return fixed_div(to_fixed(num), to_fixed(den))
}

@(private = "file")
em_half :: proc(a: Runtime_Allocator) -> Node {
	return em_fixed_node(em_fx(1, 2), a)
}

@(private = "file")
em_dt_60hz :: proc() -> Fixed {
	return fixed_div(to_fixed(1), to_fixed(60))
}

@(private = "file")
em_time :: proc(dt: Fixed, a: Runtime_Allocator) -> Record_Value {
	fields := make(map[string]Value, a)
	fields["dt"] = dt
	return Record_Value{type_name = "Time", fields = fields}
}

@(private = "file")
em_bare_interp :: proc(a: Runtime_Allocator) -> Interp {
	program := new(Program, a)
	return Interp{program = program, allocator = a}
}

@(private = "file")
interp_empty_env :: proc() -> Env {
	return Env{names = make(map[string]Value, context.temp_allocator)}
}

@(private = "file")
em_eval_call :: proc(interp: ^Interp, a: Runtime_Allocator, name: string, args: ..Node) -> Value {
	node := em_call_node(a, name, ..args)
	env := interp_empty_env()
	value, _ := eval(interp, &node, &env)
	return value
}

@(private = "file")
em_fixed_node :: proc(f: Fixed, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = em_fixed_bits(f, a)
	return Node{kind = .Fixed, fields = fields}
}

@(private = "file")
em_fixed_bits :: proc(f: Fixed, a := context.allocator) -> string {
	buf := make([]u8, 24, a)
	return strconv.write_int(buf, i64(f), 10)
}

@(private = "file")
em_int_node :: proc(n: i64, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	buf := make([]u8, 24, a)
	fields[0] = strconv.write_int(buf, n, 10)
	return Node{kind = .Int, fields = fields}
}

@(private = "file")
em_vec2_node :: proc(x, y: Fixed, a := context.allocator) -> Node {
	return em_record_node(a, "Vec2", em_recfield("x", em_fixed_node(x, a)), em_recfield("y", em_fixed_node(y, a)))
}

@(private = "file")
em_vec3_node :: proc(x, y, z: Fixed, a := context.allocator) -> Node {
	return em_record_node(
		a,
		"Vec3",
		em_recfield("x", em_fixed_node(x, a)),
		em_recfield("y", em_fixed_node(y, a)),
		em_recfield("z", em_fixed_node(z, a)),
	)
}

@(private = "file")
Em_Recfield :: struct {
	name:  string,
	value: Node,
}

@(private = "file")
em_recfield :: proc(name: string, value: Node) -> Em_Recfield {
	return Em_Recfield{name = name, value = value}
}

@(private = "file")
em_recfield_node :: proc(spec: Em_Recfield, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = spec.name
	children := make([]Node, 1, a)
	children[0] = spec.value
	return Node{kind = .Recfield, fields = fields, children = children}
}

@(private = "file")
em_record_node :: proc(a: Runtime_Allocator, type_name: string, specs: ..Em_Recfield) -> Node {
	fields := make([]string, 2, a)
	fields[0] = type_name
	buf := make([]u8, 8, a)
	fields[1] = strconv.write_int(buf, i64(len(specs)), 10)
	children := make([]Node, len(specs), a)
	for spec, i in specs {
		children[i] = em_recfield_node(spec, a)
	}
	return Node{kind = .Record, fields = fields, children = children}
}

@(private = "file")
em_name_node :: proc(name: string, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = name
	return Node{kind = .Name, fields = fields}
}

@(private = "file")
em_field_node :: proc(recv: Node, field: string, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = field
	children := make([]Node, 1, a)
	children[0] = recv
	return Node{kind = .Field, fields = fields, children = children}
}

@(private = "file")
em_binary_node :: proc(op: string, lhs, rhs: Node, a := context.allocator) -> Node {
	fields := make([]string, 1, a)
	fields[0] = op
	children := make([]Node, 2, a)
	children[0] = lhs
	children[1] = rhs
	return Node{kind = .Binary, fields = fields, children = children}
}

@(private = "file")
em_call_node :: proc(a: Runtime_Allocator, callee: string, args: ..Node) -> Node {
	children := make([]Node, len(args) + 1, a)
	children[0] = em_name_node(callee, a)
	for arg, i in args {
		children[i + 1] = arg
	}
	return Node{kind = .Call, children = children}
}

@(private = "file")
em_with_node :: proc(base: Node, a: Runtime_Allocator, specs: ..Em_Recfield) -> Node {
	children := make([]Node, len(specs) + 1, a)
	children[0] = base
	for spec, i in specs {
		children[i + 1] = em_recfield_node(spec, a)
	}
	return Node{kind = .With, children = children}
}

@(private = "file")
em_return_node :: proc(value: Node, a := context.allocator) -> Node {
	children := make([]Node, 1, a)
	children[0] = value
	return Node{kind = .Return, children = children}
}

@(private = "file")
em_tuple_node :: proc(a: Runtime_Allocator, elements: ..Node) -> Node {
	children := make([]Node, len(elements), a)
	copy(children, elements)
	return Node{kind = .Tuple, children = children}
}

@(private = "file")
em_empty_list_node :: proc(a: Runtime_Allocator) -> Node {
	return Node{kind = .List, children = make([]Node, 0, a)}
}

@(private = "file")
expect_int :: proc(t: ^testing.T, v: Value, want: i64, label: string) {
	got, ok := v.(i64)
	testing.expectf(t, ok, "%s: expected Int, got %v", label, v)
	testing.expectf(t, got == want, "%s: got %d, want %d", label, got, want)
}
