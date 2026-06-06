// Interpreter proof over the §2.7 node forest: the evaluator computes the
// canonical semantics of pong's function and behavior bodies straight from the
// golden artifact (spec §09 §1 — the interpreter IS the semantics, no source on
// its path). These tests pin the worked examples the loader tests reference
// (advance, overlaps, goal_side, serve_velocity, add_goal) to their bit-exact
// kernel results, so a body's MEANING is asserted, not just its shape.
package funpack_runtime

import "core:testing"

// make_interp builds a read-only interpreter over the golden program with an
// empty input snapshot and the fixed 60hz dt — the context a helper-body
// evaluation reads against. The version is the empty initial one; tests that
// need rows commit their own.
@(private = "file")
make_interp :: proc(program: ^Program, version: ^World_Version) -> Interp {
	dt_fields := make(map[string]Value, context.temp_allocator)
	dt_fields["dt"] = dt_60hz()
	time := Record_Value{type_name = "Time", fields = dt_fields}
	return new_interp(program, version, nil, empty(), time, context.temp_allocator)
}

// dt_60hz is the fixed 60hz step the Time resource carries: 1/60 in Q32.32,
// derived through the kernel so no float reaches the value.
@(private = "file")
dt_60hz :: proc() -> Fixed {
	return fixed_div(to_fixed(1), to_fixed(60))
}

// BOARD reads as the interpreted Board const: a body that reads BOARD.w/h
// resolves against this evaluated record with no source needed (§9 const path).
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

// advance(at, vel, dt) returns at + vel*dt — the §2.7 worked example. With
// at=(80,60), vel=(70,40), dt=1/60, the result is the bit-exact kernel value, so
// a body's arithmetic is the determinism path, not a float.
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

// goal_side(at) returns Some(Right) for x<0, Some(Left) for x>BOARD.w, None
// otherwise — the §2.7 three-statement if_return/return example. Both edges and
// the in-bounds case are forced, so the match a behavior runs over it is exact.
@(test)
test_eval_goal_side_all_arms :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)
	interp := make_interp(&program, &version)

	// x < 0 → Some(Right).
	left_edge := goal_side_case(&interp, Vec2{fixed_neg(to_fixed(5)), to_fixed(60)})
	testing.expect_value(t, left_edge.case_name, "Some")
	testing.expect_value(t, left_edge.payload.(Variant_Value).case_name, "Right")

	// x > BOARD.w (160) → Some(Left).
	right_edge := goal_side_case(&interp, Vec2{to_fixed(200), to_fixed(60)})
	testing.expect_value(t, right_edge.case_name, "Some")
	testing.expect_value(t, right_edge.payload.(Variant_Value).case_name, "Left")

	// 0 ≤ x ≤ 160 → None.
	in_bounds := goal_side_case(&interp, Vec2{to_fixed(80), to_fixed(60)})
	testing.expect_value(t, in_bounds.case_name, "None")
}

// add_goal(score, goal) increments the side the goal scored — the §2.7 match-over-
// a-field-scrutinee example. A Left goal bumps left, a Right goal bumps right;
// the OTHER column is left untouched, proving the `with` is a functional update.
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
	testing.expect_value(t, out.fields["right"].(i64), i64(5)) // untouched
}

// serve_velocity(side) returns the §2.7 match-over-an-enum example: Left serves
// (+70, +40), Right serves (−70, +40). The kernel-negated x proves the unary neg
// arm folds bit-exact.
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

// input.axis(P1, Drive::Move) resolves the 2D analog read off the snapshot
// through the eval_method_call `axis` arm (§23 §2). A snapshot carrying a known
// 2D axis returns that exact Vec2; an unwritten axis returns VEC2_ZERO (the
// snapshot default — input never faults). Mirrors the input.value contract, the
// 1D sibling on the same dispatch. Proven on a HAND-BUILT minimal program +
// snapshot, not the emitted artifact: the registry is minted from a one-Axis-enum
// program, and the call node forest is built by hand.
@(test)
test_eval_input_axis_reads_snapshot :: proc(t: ^testing.T) {
	program := axis_program()
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)

	// A snapshot with Drive::Move written for P1 to a known 2D vector. The action
	// id is 0 — the first (only) variant of the only Axis enum, per the registry's
	// declaration-order mint.
	move := Vec2{fixed_div(to_fixed(1), to_fixed(2)), fixed_neg(fixed_div(to_fixed(1), to_fixed(4)))}
	snap := with_axis(empty(), .P1, ActionId(0), move)
	defer delete_input(snap)

	dt_fields := make(map[string]Value, context.temp_allocator)
	dt_fields["dt"] = dt_60hz()
	time := Record_Value{type_name = "Time", fields = dt_fields}
	interp := new_interp(&program, &version, nil, snap, time, context.temp_allocator)

	// Registry actually minted Drive::Move as an Axis action.
	_, has_move := interp.registry.by_name["Drive::Move"]
	testing.expect(t, has_move)

	got, ok := eval_axis_call(&interp, "P1", "Drive", "Move")
	testing.expect(t, ok)
	vec := got.(Vec2)
	testing.expect_value(t, vec.x, move.x)
	testing.expect_value(t, vec.y, move.y)
}

// An axis the snapshot never wrote reads VEC2_ZERO: P2 has no Drive::Move written,
// so the §23 §2 default reading is the zero vector — the no-fault contract the 1D
// value() path also honors.
@(test)
test_eval_input_axis_unwritten_reads_zero :: proc(t: ^testing.T) {
	program := axis_program()
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)

	// Only P1 is written; P2 is left unwritten so its read falls to the default.
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

// length((3.0, 4.0)) evaluates to exactly 5.0 in Q32.32 through the eval_named_call
// `length` dispatch arm — the §10 perfect-square case fixed_sqrt resolves bit-exact
// (3²+4²=25, sqrt(25)=5, no float on the path, §10.5). Driven through a hand-built
// `length(v)` call node forest over a seeded env so the dispatch arm is exercised,
// not vec2_length in isolation.
@(test)
test_eval_length_perfect_square :: proc(t: ^testing.T) {
	program := Program{}
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)
	interp := make_interp(&program, &version)

	got, ok := eval_length_call(&interp, Vec2{to_fixed(3), to_fixed(4)})
	testing.expect(t, ok)
	testing.expect_value(t, got.(Fixed), to_fixed(5))
}

// length((1.0, 1.0)) is the non-perfect-square floor case: sqrt(2) has no exact
// Q32.32 representation, so the result is fixed_sqrt's floor-rounded value. Pinned
// bit-for-bit to the kernel result so the dispatch arm returns the EXACT kernel
// bits, never a re-rounded or float-derived magnitude (§10.5).
@(test)
test_eval_length_floor_case :: proc(t: ^testing.T) {
	program := Program{}
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)
	interp := make_interp(&program, &version)

	v := Vec2{to_fixed(1), to_fixed(1)}
	got, ok := eval_length_call(&interp, v)
	testing.expect(t, ok)
	// The kernel value is the floor of sqrt(2) in Q32.32 — assert the dispatch arm
	// returns it bit-for-bit, the same path vec2_length folds.
	testing.expect_value(t, got.(Fixed), fixed_sqrt(vec2_dot(v, v)))
}

// length over a non-Vec2 arg is ok=false (fail-closed): the magnitude of a scalar
// is undefined and never coerced, so the dispatch arm rejects it rather than
// returning a value the §10 contract cannot define.
@(test)
test_eval_length_non_vec2_fails :: proc(t: ^testing.T) {
	program := Program{}
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)
	interp := make_interp(&program, &version)

	_, ok := eval_length_call(&interp, to_fixed(7))
	testing.expect(t, !ok)
}

// --- test call helpers ----------------------------------------------------

// axis_program is a minimal program carrying one Axis enum (Drive::Move) so the
// registry mints exactly one Axis action with ActionId 0 — the hand-built
// stand-in for the artifact's action surface, mirroring the registry's
// declaration-order mint without loading a full artifact.
@(private = "file")
axis_program :: proc() -> Program {
	enums := make([]Enum_Decl, 1, context.temp_allocator)
	variants := make([]Enum_Variant, 1, context.temp_allocator)
	variants[0] = Enum_Variant{name = "Move", payload = "unit"}
	enums[0] = Enum_Decl{name = "Drive", kind = .Axis, variants = variants}
	return Program{enums = enums}
}

// eval_axis_call builds and evaluates an `input.axis(PlayerId::player, Enum::case)`
// method-call node forest by hand — a `.Call` over a `.Field` callee (`input.axis`,
// receiver bound through the env) plus two `.Variant` args — driving the dispatch
// the executed pipeline reaches without lowering an artifact.
@(private = "file")
eval_axis_call :: proc(
	interp: ^Interp,
	player, action_enum, action_case: string,
) -> (
	result: Value,
	ok: bool,
) {
	// The receiver `input`, the `input.axis` field callee, and the two Variant args
	// are built into a `.Call` forest. Every node's field/children slice is heap-
	// allocated (temp arena) so the forest survives this proc's return — Odin
	// refuses a compound slice literal escaping a stack frame.
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

// eval_length_call builds and evaluates a `length(v)` named-call node forest by
// hand — a `.Call` over a `.Name` callee (`length`) with a single `.Name` arg
// (`v`) that resolves the supplied value out of a seeded env — so the
// eval_named_call `length` dispatch arm is exercised, not vec2_length in
// isolation. Reuses the node_fields/node_children heap-allocators (a compound
// slice literal cannot escape this stack frame in Odin).
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

// variant_node builds a unit-payload `.Variant` body node — `variant ENUM CASE
// false` — the shape eval_variant decodes into a Variant_Value. Used to hand-build
// the PlayerId and action args a resource query reads.
@(private = "file")
variant_node :: proc(enum_type, case_name: string) -> Node {
	return Node{kind = .Variant, fields = node_fields(enum_type, case_name, "false")}
}

// node_fields heap-allocates a node's scalar-token slice from the temp arena, so a
// hand-built node can escape its constructing stack frame.
@(private = "file")
node_fields :: proc(tokens: ..string) -> []string {
	out := make([]string, len(tokens), context.temp_allocator)
	copy(out, tokens)
	return out
}

// node_children heap-allocates a node's child slice from the temp arena, mirroring
// node_fields for the children axis.
@(private = "file")
node_children :: proc(nodes: ..Node) -> []Node {
	out := make([]Node, len(nodes), context.temp_allocator)
	copy(out, nodes)
	return out
}

// call_three applies a three-arg §9 helper directly by building a call over name
// nodes that resolve from a seeded scope — the test driver for a body whose args
// are runtime values rather than literals.
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

// call_two applies a two-arg §9 helper directly against seeded params.
@(private = "file")
call_two :: proc(interp: ^Interp, name: string, a, b: Value) -> (result: Value, ok: bool) {
	fn := program_function(interp.program, name)
	if fn == nil || len(fn.params) != 2 {
		return nil, false
	}
	return apply_two_arg(interp, fn, a, b)
}

// call_one applies a one-arg §9 helper directly against its seeded param.
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

// goal_side_case runs goal_side over a position and returns the resulting Option
// variant for arm inspection.
@(private = "file")
goal_side_case :: proc(interp: ^Interp, at: Vec2) -> Variant_Value {
	result, ok := call_one(interp, "goal_side", at)
	if !ok {
		return Variant_Value{}
	}
	return result.(Variant_Value)
}

// serve_velocity_for runs serve_velocity over a side variant and returns the Vec2.
@(private = "file")
serve_velocity_for :: proc(interp: ^Interp, side: string) -> Vec2 {
	result, ok := call_one(interp, "serve_velocity", side_value(interp, side))
	if !ok {
		return VEC2_ZERO
	}
	return result.(Vec2)
}

// record_value builds a Record_Value fixture from name/value pairs — the
// descriptor-driven stand-in for a typed record literal in a test.
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

// side_value builds a Side enum variant value for a serve/score fixture.
@(private = "file")
side_value :: proc(interp: ^Interp, case_name: string) -> Value {
	return Variant_Value{enum_type = "Side", case_name = case_name}
}

// goal_value builds a Goal signal record carrying a side — the element add_goal
// folds and serve reads.
@(private = "file")
goal_value :: proc(interp: ^Interp, side: string) -> Value {
	fields := make(map[string]Value, interp.allocator)
	fields["side"] = side_value(interp, side)
	return Record_Value{type_name = "Goal", fields = fields}
}
